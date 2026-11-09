import SwiftUI

/// Live tuning panel shared by BlurLab and the menu bar app.
struct TuningView: View {
    @ObservedObject var engine: EffectEngine

    var body: some View {
        Form {
            Section("진행도") {
                Picker("입력", selection: $engine.inputMode) {
                    Text("덮개 각도 센서").tag(EffectEngine.InputMode.sensor)
                    Text("디버그 슬라이더").tag(EffectEngine.InputMode.manual)
                }
                .pickerStyle(.segmented)
                .onChange(of: engine.inputMode) { _, _ in engine.persistMode() }
                ParamSlider("디버그 진행도 (1 = 열림)", value: $engine.manualProgress, range: 0...1)
                    .disabled(engine.inputMode != .manual)
                LiveStatusRows(status: engine.status)
                Button("닫힘→열림 대체 애니메이션 미리보기") { engine.playOpenAnimation() }
                EventLogToggle()
            }
            Section("스타일") {
                Picker("효과", selection: $engine.params.style) {
                    Text("바깥 화면처럼 기울기 (사다리꼴 + 블러)").tag(EffectStyle.coverPanel)
                    Text("평면 그라디언트 블러").tag(EffectStyle.gradient)
                }
            }
            if engine.params.style == .coverPanel {
                Section("기울기 / 원근") {
                    ParamSlider("완전히 닫힐 때 기울기", value: $engine.params.coverTiltMax, range: 0...90, format: "%.0f°")
                    ParamSlider("카메라 거리 (화면 높이 배)", value: $engine.params.coverCameraDistance, range: 1...12)
                    ParamSlider("카메라 높이 (시작)", value: $engine.params.coverCameraHeightStart, range: 0...1)
                    ParamSlider("카메라 높이 (끝)", value: $engine.params.coverCameraHeightEnd, range: 0...1)
                    Toggle("위아래로 눌리지 않게 (높이 유지)", isOn: $engine.params.coverKeepHeight)
                    ParamSlider("내용 밀림", value: $engine.params.coverContentShift, range: 0...0.5, format: "%.3f")
                    Toggle("블러·음영이 경첩(아래) 쪽으로 강해짐 (원본은 꺼짐: 바깥쪽 끝으로 강해짐)", isOn: $engine.params.coverTowardHinge)
                }
                Section("블러 / 음영 (원본 공식)") {
                    ParamSlider("완전 기울기에서 wipe", value: $engine.params.coverWipeAtFullTilt, range: 0...1)
                    ParamSlider("블러 이득", value: $engine.params.coverBlurGain, range: 0...6)
                    ParamSlider("블러 구간 시작", value: $engine.params.coverBlurStart, range: 0...1)
                    ParamSlider("블러 구간 끝", value: $engine.params.coverBlurEnd, range: 0.05...1)
                    ParamSlider("LOD 배율", value: $engine.params.coverLodScale, range: 0...12)
                    ParamSlider("기준 텍스처 크기(px)", value: $engine.params.coverReferencePx, range: 200...3000, format: "%.0f")
                    ParamSlider("블러 연동 최저 밝기", value: $engine.params.coverShadeLow, range: 0...1)
                    ParamSlider("경첩 쪽 어두워짐 이득", value: $engine.params.coverWipeShadeGain, range: 0...6)
                    ParamSlider("좌우 가장자리 띠", value: $engine.params.coverEdgeBand, range: 0.001...0.5, format: "%.3f")
                    ParamSlider("좌우 띠가 다 나타나는 wipe", value: $engine.params.coverEdgeFadeWipe, range: 0.001...0.5, format: "%.3f")
                }
            }
            Section("덮개 각도 → 진행도") {
                ParamSlider("효과 시작 각도", value: $engine.params.openAngle, range: 30...140, format: "%.0f°")
                ParamSlider("최대 효과 각도", value: $engine.params.closedAngle, range: 0...90, format: "%.0f°")
                ParamSlider("매핑 곡선 지수", value: $engine.params.angleCurve, range: 0.3...3)
            }
            if engine.params.style == .gradient {
            Section("블러") {
                Picker("방향", selection: $engine.params.direction) {
                    Text("위쪽(덮개 끝)으로 강해짐").tag(GradientDirection.towardOuterEdge)
                    Text("아래쪽(경첩)으로 강해짐").tag(GradientDirection.towardHinge)
                }
                Picker("필터", selection: $engine.params.filter) {
                    Text("부드러운 피라미드").tag(BlurFilter.smooth)
                    Text("밉맵 (trilinear)").tag(BlurFilter.mipmap)
                }
                ParamSlider("최대 블러 (LOD)", value: $engine.params.maxBlur, range: 0...12)
                ParamSlider("경첩 쪽 블러 비율", value: $engine.params.hingeBlur, range: 0...1)
                ParamSlider("구간 시작", value: $engine.params.blurStart, range: 0...1)
                ParamSlider("구간 끝", value: $engine.params.blurEnd, range: 0...1)
                ParamSlider("공간 곡선 지수 (pow)", value: $engine.params.blurCurve, range: 0.2...4)
                ParamSlider("진행 기본량", value: $engine.params.blurBase, range: 0...1)
                ParamSlider("진행 기울기", value: $engine.params.blurSlope, range: 0...5)
                ParamSlider("진행 시작 구간", value: $engine.params.blurOnset, range: 0.005...0.5, format: "%.3f")
                Toggle("화면 크기에 비례", isOn: $engine.params.scaleToPanel)
            }
            Section("음영") {
                ParamSlider("전체 어두워짐", value: $engine.params.shadeUniform, range: 0...1.5)
                ParamSlider("전체 어두워짐 곡선", value: $engine.params.shadeUniformCurve, range: 0.3...4)
                ParamSlider("끝쪽 어두워짐", value: $engine.params.shadeEdge, range: 0...1)
                ParamSlider("끝쪽 포화 지점", value: $engine.params.shadeEdgeFull, range: 0.05...1)
                ParamSlider("끝쪽 진행 곡선", value: $engine.params.shadeEdgeCurve, range: 0.3...4)
                ParamSlider("끝쪽 시작 위치", value: $engine.params.shadeStart, range: 0...0.9)
                ParamSlider("끝쪽 공간 곡선", value: $engine.params.shadeCurve, range: 0.3...4)
                ParamSlider("좌우 가장자리 어두워짐", value: $engine.params.sideShade, range: 0...1)
                ParamSlider("좌우 가장자리 폭", value: $engine.params.sideWidth, range: 0.005...0.3, format: "%.3f")
                ParamSlider("최소 밝기", value: $engine.params.minShading, range: 0...1)
            }
            }
            Section("성능") {
                Picker("최대 프레임 속도", selection: $engine.params.maxFrameRate) {
                    Text("60 Hz (배터리 절약)").tag(60.0)
                    Text("120 Hz (ProMotion)").tag(120.0)
                }
                .pickerStyle(.segmented)
            }
            Section("스무딩") {
                ParamSlider("lerp (입력 추종)", value: $engine.params.lerpDrag, range: 0.01...1, format: "%.3f")
                ParamSlider("lerp (대체 애니메이션)", value: $engine.params.lerpSnap, range: 0.01...1, format: "%.3f")
            }
            Section {
                HStack {
                    Button("기본값으로 되돌리기") { engine.params = .default }
                    Spacer()
                    Button("설정값 복사") {
                        if let d = try? JSONEncoder().encode(engine.params), let s = String(data: d, encoding: .utf8) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ParamSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String = "%.2f") {
        self.title = title; self._value = value; self.range = range; self.format = format
    }

    var body: some View {
        HStack {
            Text(title).frame(width: 170, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}

struct EventLogToggle: View {
    @State private var on = EventLog.shared.enabled
    var body: some View {
        HStack {
            Toggle("실기기 측정 로그 기록", isOn: $on).onChange(of: on) { _, v in EventLog.shared.enabled = v }
            Spacer()
            Button("로그 보기") { if let u = EventLog.shared.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
        }
    }
}

struct LiveStatusRows: View {
    @ObservedObject var status: LiveStatus
    var body: some View {
        LabeledContent("현재 각도", value: status.angle.map { String(format: "%.0f°", $0) } ?? "—")
        LabeledContent("현재 진행도", value: String(format: "%.3f", status.progress))
        LabeledContent("센서", value: status.sensorStatus)
        LabeledContent("캡처", value: status.captureStatus)
    }
}
