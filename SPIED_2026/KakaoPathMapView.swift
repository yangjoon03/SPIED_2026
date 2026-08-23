//
//  KakaoPathMapView.swift
//  SPIED_2026
//
//  Renders a KakaoMap and draws the walking path traced by GPS points
//  streamed in from GalaxyBridgeClient.
//

import SwiftUI
import KakaoMapsSDK
import Combine
import CoreLocation

struct KakaoPathMapView: UIViewRepresentable {
    let galaxy: GalaxyBridgeClient
    @Binding var isActive: Bool
    @Binding var isRecording: Bool
    /// 목적지까지의 도보 경로. 비어 있으면 표시 안 함.
    @Binding var routeCoordinates: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> KMViewContainer {
        let view = KMViewContainer()
        view.sizeToFit()
        context.coordinator.createController(view)
        context.coordinator.controller?.prepareEngine()
        return view
    }

    func updateUIView(_ uiView: KMViewContainer, context: Context) {
        if isActive {
            context.coordinator.controller?.activateEngine()
        } else {
            context.coordinator.controller?.resetEngine()
        }
        context.coordinator.isRecording = isRecording
        context.coordinator.updateRoute(routeCoordinates)
        context.coordinator.syncViewRect(with: uiView.bounds.size)
    }

    func makeCoordinator() -> PathMapCoordinator {
        PathMapCoordinator(galaxy: galaxy)
    }

    static func dismantleUIView(_ uiView: KMViewContainer, coordinator: PathMapCoordinator) {
        coordinator.controller?.pauseEngine()
        coordinator.controller?.resetEngine()
    }
}

final class PathMapCoordinator: NSObject, MapControllerDelegate {
    private static let shapeLayerID = "walkingPathLayer"
    private static let polylineStyleSetID = "walkingPathStyle"
    private static let pathShapeID = "walkingPathShape"
    private static let labelLayerID = "currentPositionLayer"
    private static let poiStyleID = "currentPositionStyle"
    private static let poiHeadingStyleID = "currentPositionHeadingStyle"
    private static let poiID = "currentPositionPoi"
    private static let routeStyleSetID = "plannedRouteStyle"
    private static let routeShapeID = "plannedRouteShape"
    private static let destinationPoiStyleID = "destinationMarkerStyle"
    private static let destinationPoiID = "destinationMarkerPoi"

    var controller: KMController?
    /// 기본값은 기록 안 함. `KakaoPathMapView`의 `isRecording` 바인딩으로 켜고 끈다.
    /// 꺼져 있어도 현재 위치 마커/카메라 추적은 계속 동작하고, 지나온 경로 선만 안 그린다.
    var isRecording = false
    private let galaxy: GalaxyBridgeClient
    private var cancellable: AnyCancellable?
    private var pathPoints: [MapPoint] = []
    private var currentPoi: Poi?
    private var destinationPoi: Poi?
    private var lastRoutePointCount = -1
    private var didMoveCameraOnce = false
    private weak var mapContainerView: KMViewContainer?
    /// 도보 경로 확인에 적당한 확대 수준 (이 SDK는 숫자가 클수록 더 확대됨).
    private static let walkingZoomLevel: Int = 17

    init(galaxy: GalaxyBridgeClient) {
        self.galaxy = galaxy
        super.init()
    }

    func createController(_ view: KMViewContainer) {
        mapContainerView = view
        controller = KMController(viewContainer: view)
        controller?.delegate = self
    }

    // MARK: - KMControllerDelegate

    @objc func addViews() {
        NSLog("DEBUG_MARK addViews called")
        let defaultPosition = MapPoint(
            longitude: WeatherViewModel.fixedCoordinate.longitude,
            latitude: WeatherViewModel.fixedCoordinate.latitude
        )
        let mapviewInfo = MapviewInfo(
            viewName: "mapview",
            viewInfoName: "map",
            defaultPosition: defaultPosition,
            defaultLevel: Self.walkingZoomLevel
        )
        controller?.addView(mapviewInfo)
    }

    @objc func addViewSucceeded(_ viewName: String, viewInfoName: String) {
        NSLog("DEBUG_MARK addViewSucceeded called")
        guard let mapView = controller?.getView("mapview") as? KakaoMap else {
            NSLog("DEBUG_MARK addViewSucceeded getView nil")
            return
        }

        let shapeManager = mapView.getShapeManager()
        _ = shapeManager.addShapeLayer(layerID: Self.shapeLayerID, zOrder: 10001)
        let polylineStyle = PolylineStyle(styles: [
            PerLevelPolylineStyle(bodyColor: .systemBlue, bodyWidth: 6, strokeColor: .white, strokeWidth: 2, level: 0)
        ])
        shapeManager.addPolylineStyleSet(PolylineStyleSet(styleSetID: Self.polylineStyleSetID, styles: [polylineStyle]))

        let routeStyle = PolylineStyle(styles: [
            PerLevelPolylineStyle(bodyColor: .systemOrange, bodyWidth: 6, strokeColor: .white, strokeWidth: 2, level: 0)
        ])
        shapeManager.addPolylineStyleSet(PolylineStyleSet(styleSetID: Self.routeStyleSetID, styles: [routeStyle]))

        let labelManager = mapView.getLabelManager()
        _ = labelManager.addLabelLayer(option: LabelLayerOptions(
            layerID: Self.labelLayerID,
            competitionType: .none,
            competitionUnit: .symbolFirst,
            orderType: .rank,
            zOrder: 10000
        ))
        let dotIconStyle = PoiIconStyle(symbol: Self.makeMarkerImage(pointsDirection: false), anchorPoint: CGPoint(x: 0.5, y: 0.5))
        labelManager.addPoiStyle(PoiStyle(styleID: Self.poiStyleID, styles: [
            PerLevelPoiStyle(iconStyle: dotIconStyle, level: 0)
        ]))
        let headingIconStyle = PoiIconStyle(symbol: Self.makeMarkerImage(pointsDirection: true), anchorPoint: CGPoint(x: 0.5, y: 0.5))
        labelManager.addPoiStyle(PoiStyle(styleID: Self.poiHeadingStyleID, styles: [
            PerLevelPoiStyle(iconStyle: headingIconStyle, level: 0)
        ]))
        let destinationIconStyle = PoiIconStyle(symbol: Self.makeDestinationMarkerImage(), anchorPoint: CGPoint(x: 0.5, y: 1.0))
        labelManager.addPoiStyle(PoiStyle(styleID: Self.destinationPoiStyleID, styles: [
            PerLevelPoiStyle(iconStyle: destinationIconStyle, level: 0)
        ]))

        subscribeToGalaxy()

        // The view container's own size lands before this delegate call
        // fires, so the resize notification that normally drives
        // applyViewRect(_:) can be missed. Apply the known size now that
        // the map view actually exists.
        if let size = mapContainerView?.bounds.size, size.width > 0, size.height > 0 {
            applyViewRect(size)
        }
    }

    @objc func addViewFailed(_ viewName: String, viewInfoName: String) {
        print("❌ KakaoMap addView 실패: \(viewName)/\(viewInfoName)")
    }

    @objc func containerDidResized(_ size: CGSize) {
        applyViewRect(size)
    }

    /// SwiftUI hosts KMViewContainer without triggering the SDK's own resize
    /// notification, so `updateUIView` calls this on every refresh as a fallback.
    func syncViewRect(with size: CGSize) {
        NSLog("DEBUG_MARK syncViewRect size=%@ hasMapView=%@", NSCoder.string(for: size), (controller?.getView("mapview") != nil) ? "true" : "false")
        guard size.width > 0, size.height > 0 else { return }
        applyViewRect(size)
    }

    private func applyViewRect(_ size: CGSize) {
        guard let mapView = controller?.getView("mapview") as? KakaoMap else { return }
        mapView.viewRect = CGRect(origin: .zero, size: size)

        if !didMoveCameraOnce {
            didMoveCameraOnce = true
            let target = MapPoint(
                longitude: WeatherViewModel.fixedCoordinate.longitude,
                latitude: WeatherViewModel.fixedCoordinate.latitude
            )
            let cameraUpdate = CameraUpdate.make(target: target, zoomLevel: Self.walkingZoomLevel, mapView: mapView)
            mapView.moveCamera(cameraUpdate)
        }
    }

    // MARK: - Galaxy GPS 스트림 구독

    private func subscribeToGalaxy() {
        cancellable = galaxy.events.sink { [weak self] event in
            guard case .gpsUpdate(let gps) = event else { return }
            self?.handleGPSUpdate(gps)
        }
    }

    private func handleGPSUpdate(_ gps: GPSPayload) {
        guard let mapView = controller?.getView("mapview") as? KakaoMap else { return }
        let point = MapPoint(longitude: gps.longitude, latitude: gps.latitude)

        updateCurrentPositionPoi(mapView: mapView, at: point, heading: gps.heading)

        guard isRecording else { return }
        pathPoints.append(point)

        guard pathPoints.count >= 2 else { return }

        let shapeManager = mapView.getShapeManager()
        guard let layer = shapeManager.getShapeLayer(layerID: Self.shapeLayerID) else { return }

        let line = MapPolyline(line: pathPoints, styleIndex: 0)
        if let shape = layer.getMapPolylineShape(shapeID: Self.pathShapeID) {
            shape.changeStyleAndData(styleID: Self.polylineStyleSetID, lines: [line])
        } else {
            let options = MapPolylineShapeOptions(shapeID: Self.pathShapeID, styleID: Self.polylineStyleSetID, zOrder: 10001)
            options.polylines.append(line)
            let shape = layer.addMapPolylineShape(options)
            shape?.show()
        }
    }

    private func updateCurrentPositionPoi(mapView: KakaoMap, at point: MapPoint, heading: Double?) {
        let labelManager = mapView.getLabelManager()

        if let poi = currentPoi {
            poi.position = point
            if let heading {
                poi.orientation = heading * .pi / 180
                poi.changeStyle(styleID: Self.poiHeadingStyleID)
            } else {
                poi.changeStyle(styleID: Self.poiStyleID)
            }
            // updateRoute()가 목적지 검색 후 경로 전체가 보이게 moveCamera로 카메라를
            // 직접 옮기면, SDK가 그걸 "사용자가 수동으로 지도를 조작한 것"으로 보고
            // 자동 추적을 끊어버린다. 그 뒤로는 GPS가 계속 들어와도 카메라가 다시는
            // 안 따라와서(마커 자체는 정상 갱신되는데도 화면 밖에 있는 것처럼 보임),
            // GPS가 안 되는 것처럼 오인하게 된다. 그래서 매 GPS 업데이트마다
            // 추적을 다시 걸어줘서 항상 실시간 위치를 따라가게 한다.
            mapView.getTrackingManager().startTrackingPoi(poi)
        } else {
            guard let layer = labelManager.getLabelLayer(layerID: Self.labelLayerID) else { return }
            let initialStyleID = heading != nil ? Self.poiHeadingStyleID : Self.poiStyleID
            let options = PoiOptions(styleID: initialStyleID, poiID: Self.poiID)
            options.rank = 10
            options.transformType = .absoluteRotationDecal
            let poi = layer.addPoi(option: options, at: point)
            if let heading {
                poi?.orientation = heading * .pi / 180
            }
            poi?.show()
            currentPoi = poi

            if let poi {
                mapView.getTrackingManager().startTrackingPoi(poi)
            }

            // 실제 GPS 좌표를 처음 받은 시점에 도보 확대 수준으로 스냅한다.
            let cameraUpdate = CameraUpdate.make(target: point, zoomLevel: Self.walkingZoomLevel, mapView: mapView)
            mapView.moveCamera(cameraUpdate)
        }
    }

    // MARK: - 목적지 도보 경로

    /// `routeCoordinates` 바인딩이 바뀔 때마다 호출된다. GPS 스트림 때문에 매 프레임 호출되므로
    /// 좌표 개수로만 변경 여부를 판단해 불필요한 재작업을 피한다.
    func updateRoute(_ coordinates: [CLLocationCoordinate2D]) {
        guard coordinates.count != lastRoutePointCount else { return }
        lastRoutePointCount = coordinates.count
        guard let mapView = controller?.getView("mapview") as? KakaoMap else { return }

        let shapeManager = mapView.getShapeManager()
        guard let layer = shapeManager.getShapeLayer(layerID: Self.shapeLayerID) else { return }

        guard !coordinates.isEmpty else {
            layer.getMapPolylineShape(shapeID: Self.routeShapeID)?.hide()
            destinationPoi?.hide()
            return
        }

        let points = coordinates.map { MapPoint(longitude: $0.longitude, latitude: $0.latitude) }
        let line = MapPolyline(line: points, styleIndex: 0)
        if let shape = layer.getMapPolylineShape(shapeID: Self.routeShapeID) {
            shape.changeStyleAndData(styleID: Self.routeStyleSetID, lines: [line])
            shape.show()
        } else {
            let options = MapPolylineShapeOptions(shapeID: Self.routeShapeID, styleID: Self.routeStyleSetID, zOrder: 10002)
            options.polylines.append(line)
            let shape = layer.addMapPolylineShape(options)
            shape?.show()
        }

        updateDestinationMarker(at: points[points.count - 1], mapView: mapView)

        let area = AreaRect(points: points)
        mapView.moveCamera(CameraUpdate.make(area: area, levelLimit: Self.walkingZoomLevel))
    }

    private func updateDestinationMarker(at point: MapPoint, mapView: KakaoMap) {
        let labelManager = mapView.getLabelManager()
        if let poi = destinationPoi {
            poi.position = point
            poi.show()
        } else {
            guard let layer = labelManager.getLabelLayer(layerID: Self.labelLayerID) else { return }
            let options = PoiOptions(styleID: Self.destinationPoiStyleID, poiID: Self.destinationPoiID)
            options.rank = 15
            let poi = layer.addPoi(option: options, at: point)
            poi?.show()
            destinationPoi = poi
        }
    }

    private static func makeDestinationMarkerImage() -> UIImage {
        let size = CGSize(width: 36, height: 44)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let pin = UIBezierPath()
            let topRadius: CGFloat = 14
            let center = CGPoint(x: size.width / 2, y: topRadius + 2)
            pin.addArc(withCenter: center, radius: topRadius, startAngle: .pi * 0.85, endAngle: .pi * 0.15, clockwise: false)
            pin.addLine(to: CGPoint(x: size.width / 2, y: size.height - 2))
            pin.close()
            UIColor.systemOrange.setFill()
            pin.fill()
            UIColor.white.setStroke()
            pin.lineWidth = 2
            pin.stroke()

            let dotRect = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: dotRect).fill()
        }
    }

    /// 파란 점 + 진행 방향을 가리키는 화살촉. `orientation`(라디안, 0 = 이미지 기준 "위쪽")으로
    /// 회전하면 화살촉이 실제 진행 방향을 가리킨다. heading이 없을 때(정지 상태)는 화살촉 없이
    /// 점만 보이도록 별도 스타일을 둔다.
    private static func makeMarkerImage(pointsDirection: Bool) -> UIImage {
        let size = CGSize(width: 44, height: 44)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let dotRadius: CGFloat = 8

            if pointsDirection {
                let cone = UIBezierPath()
                cone.move(to: CGPoint(x: center.x, y: 2))
                cone.addLine(to: CGPoint(x: center.x - 13, y: center.y + 2))
                cone.addLine(to: CGPoint(x: center.x + 13, y: center.y + 2))
                cone.close()
                UIColor.systemBlue.withAlphaComponent(0.35).setFill()
                cone.fill()
            }

            let dotRect = CGRect(
                x: center.x - dotRadius, y: center.y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )
            let dot = UIBezierPath(ovalIn: dotRect)
            UIColor.systemBlue.setFill()
            dot.fill()
            UIColor.white.setStroke()
            dot.lineWidth = 3
            dot.stroke()
        }
    }
}
