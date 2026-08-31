"""
로컬 YOLO 세그멘테이션 서버 — 원격 추론 서버와 동일한 /health, /predict 계약을
그대로 구현한다. 그래서 iOS 앱(SegmentationService.swift)은 baseURL만 바꾸면
코드 수정 없이 붙는다.

실행 (Claude conda 환경에서):
    conda activate Claude
    cd galaxy-bridge
    python local_segmentation_server.py
"""

import base64
import time

import cv2
import numpy as np
import torch
import uvicorn
from fastapi import FastAPI, File, Query, UploadFile
from fastapi.responses import JSONResponse
from ultralytics import YOLO

MODEL_PATH = "last.pt"
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"
PORT = 8002

# 영어 카테고리 키 -> 한글 라벨. 모델의 클래스 이름(model.names)은 한글이라,
# 시각장애인용 영어 음성 명령("find door")이 어떤 한글 클래스와 매칭되는지
# 알려주려면 역방향(한글 -> 영어)으로 뒤집어서 쓴다.
CATEGORIES = {
    "flatness_A": "평탄성 A(Very Good)", "flatness_B": "평탄성 B(Good)",
    "flatness_C": "평탄성 C(Fair)", "flatness_D": "평탄성 D(Poor)",
    "flatness_E": "평탄성 E(Very Poor)", "walkway_block": "보도블럭",
    "paved_state_broken": "포장도로 파손", "paved_state_normal": "포장도로 정상",
    "block_state_broken": "보도블럭 파손", "block_state_normal": "보도블럭 정상",
    "block_kind_bad": "주행성 나쁨", "block_kind_good": "주행성 좋음",
    "outcurb_rectangle": "사각모서리 연석 정상", "outcurb_slide": "경사형 연석 정상",
    "outcurb_rectangle_broken": "사각모서리 연석 파손", "outcurb_slide_broken": "경사형 연석 파손",
    "restspace": "휴식참", "sidegap_in": "문턱 (실내)", "sidegap_out": "문턱 (실외)",
    "sewer_cross": "격자형 배수구", "sewer_line": "비 격자형 배수구",
    "brailleblock_dot": "점형블록", "brailleblock_line": "선형블록",
    "brailleblock_dot_broken": "점형블록 파손", "brailleblock_line_broken": "선형블록 파손",
    "continuity_tree": "연속하지 않음 (가로수영역)", "continuity_manhole": "연속하지 않음 (맨홀)",
    "ramp_yes": "미끄럼방지 있는 경사로", "ramp_no": "미끄럼방지 없는 경사로",
    "bicycleroad_broken": "자전거 도로 파손", "bicycleroad_normal": "자전거 도로 정상",
    "planecrosswalk_broken": "평면횡단보도 파손", "planecrosswalk_normal": "평면횡단보도 정상",
    "steepramp": "부분경사로", "bump_slow": "과속방지턱", "bump_zigzag": "지그재그형 도로",
    "weed": "잡초", "floor_normal": "복도 바닥 정상", "floor_broken": "복도 바닥 파손",
    "flowerbed": "화단", "packspace": "주차공간", "tirebump": "타이어 방지턱",
    "stone": "경관용 돌", "enterrail": "주출입문 레일", "fireshutter": "방화셔터 바닥홈",
    "stair_normal": "계단", "stair_broken": "계단 파손", "wall": "벽",
    "window_sliding": "미서기창", "window_casement": "여닫이창", "pillar": "기둥",
    "lift": "승강기 (시설)", "door_normal": "문", "door_rotation": "회전문",
    "lift_door": "승강기 출입문", "resting_place_roof": "휴게시설", "reception_desk": "접수대",
    "protect_wall_protective": "방호울타리", "protect_wall_guardrail": "접근방지용 난간",
    "protect_wall_kikeplate": "킥플레이트", "handle_vertical": "수직막대형 손잡이",
    "handle_lever": "레버형 손잡이", "handle_circular": "원형손잡이",
    "lift_button_normal": "승강기 조작설비 일반", "lift_button_openarea": "문열림닫침 영역",
    "lift_button_layer": "층수영역", "lift_button_emergency": "비상벨영역",
    "direction_sign_left": "왼쪽이동표식", "direction_sign_right": "오른쪽이동표식",
    "direction_sign_straight": "화살표", "direction_sign_exit": "출구표식",
    "sign_disabled_toilet": "화장실표지판", "sign_disabled_parking": "주차표지판",
    "sign_disabled_elevator": "교통약자 전용 엘레베이터 표지판",
    "sign_disabled_ramp": "경사로 안내 표지판", "sign_disabled_callbell": "비상 호출벨 안내표지판",
    "sign_disabled_icon": "장애인 픽토그램", "braile_sign": "점자표지판",
    "chair_multi": "다인용 평의자", "chair_one": "일인용 의자", "chair_circular": "원형 의자",
    "chair_back": "등받이가 있는 휴게 의자", "chair_handle": "손잡이가 있는 휴게 의자",
    "beverage_vending_machine": "판매기", "beverage_desk": "음료대",
    "trash_can": "휴지통", "mailbox": "우체통",
}
KO_TO_EN = {ko: en for en, ko in CATEGORIES.items()}

app = FastAPI()
model = YOLO(MODEL_PATH)
model.to(DEVICE)

# MPS(Apple GPU)는 첫 추론에서 Metal 셰이더를 컴파일하느라 15~20초씩
# 걸린다. 서버가 요청을 받기 전에 미리 한 번 돌려서 첫 사용자가 그
# 지연을 겪지 않게 한다.
def _warmup():
    dummy = np.zeros((640, 640, 3), dtype=np.uint8)
    start = time.perf_counter()
    model.predict(dummy, conf=0.25, device=DEVICE, verbose=False)
    print(f"warmup done in {time.perf_counter() - start:.2f}s")


_warmup()


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_PATH, "device": DEVICE}


@app.post("/predict")
async def predict(file: UploadFile = File(...), conf: float = Query(0.25)):
    try:
        raw = await file.read()
        buf = np.frombuffer(raw, dtype=np.uint8)
        img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        if img is None:
            return JSONResponse({"error": "이미지를 디코딩할 수 없습니다."})

        start = time.perf_counter()
        results = model.predict(img, conf=conf, device=DEVICE, verbose=False)
        inference_ms = (time.perf_counter() - start) * 1000

        result = results[0]
        img_width = img.shape[1]
        img_height = img.shape[0]
        detections = []
        if result.boxes is not None:
            for box in result.boxes:
                cls_id = int(box.cls[0])
                class_name_ko = model.names[cls_id]

                x1, y1, x2, y2 = box.xyxy[0].tolist()
                center_x = (x1 + x2) / 2
                fraction_x = center_x / img_width if img_width > 0 else 0.5
                if fraction_x < 1 / 3:
                    position = "left"
                elif fraction_x > 2 / 3:
                    position = "right"
                else:
                    position = "center"

                # 세로 위치: 화면 아래쪽(발밑에 가까움)="near", 위쪽(멀리 뻗어있음)="far".
                # 박스의 아래쪽 변(y2)을 기준으로 잡는다 — 바닥에 붙은 사물일수록 y2가
                # 실제 지면 위치에 가깝기 때문에 상단(y1)보다 "얼마나 가까운지"를 더 잘 나타낸다.
                fraction_y = y2 / img_height if img_height > 0 else 0.5
                if fraction_y > 2 / 3:
                    depth = "near"
                elif fraction_y < 1 / 3:
                    depth = "far"
                else:
                    depth = "mid"

                detections.append({
                    "class_name": class_name_ko,
                    "class_name_en": KO_TO_EN.get(class_name_ko, class_name_ko),
                    "confidence": float(box.conf[0]),
                    "position": position,
                    "depth": depth,
                })

        vis = result.plot()
        ok, jpg = cv2.imencode(".jpg", vis, [cv2.IMWRITE_JPEG_QUALITY, 85])
        vis_b64 = base64.b64encode(jpg.tobytes()).decode("utf-8")

        return {
            "count": len(detections),
            "inference_ms": round(inference_ms, 2),
            "detections": detections,
            "visualization": vis_b64,
            "image_size": [img.shape[1], img.shape[0]],
            "error": None,
        }
    except Exception as e:
        return JSONResponse({"error": str(e)})


if __name__ == "__main__":
    print(f"device = {DEVICE}")
    uvicorn.run(app, host="0.0.0.0", port=PORT)
