import SwiftUI

/// Live tuning panel shared by BlurLab and the menu bar app.
struct TuningView: View {
    @ObservedObject var engine: EffectEngine

    var body: some View {
        Form {
            Section("Progress") {
                Picker("Input", selection: $engine.inputMode) {
                    Text("Lid angle sensor").tag(EffectEngine.InputMode.sensor)
                    Text("Debug slider").tag(EffectEngine.InputMode.manual)
                }
                .pickerStyle(.segmented)
                .onChange(of: engine.inputMode) { _, _ in engine.persistMode() }
                ParamSlider("Debug progress (1 = open)", value: $engine.manualProgress, range: 0...1)
                    .disabled(engine.inputMode != .manual)
                LiveStatusRows(status: engine.status)
                Button("Preview the closed → open fallback animation") { engine.playOpenAnimation() }
                EventLogToggle()
            }
            Section("Style") {
                Picker("Effect", selection: $engine.params.style) {
                    Text("Tilt like a cover screen (trapezoid + blur)").tag(EffectStyle.coverPanel)
                    Text("Flat gradient blur").tag(EffectStyle.gradient)
                }
            }
            if engine.params.style == .coverPanel {
                Section("Tilt / Perspective") {
                    ParamSlider("Tilt when fully closed", value: $engine.params.coverTiltMax, range: 0...90, format: "%.0f°")
                    ParamSlider("Camera distance (× screen height)", value: $engine.params.coverCameraDistance, range: 1...12)
                    ParamSlider("Camera height (start)", value: $engine.params.coverCameraHeightStart, range: 0...1)
                    ParamSlider("Camera height (end)", value: $engine.params.coverCameraHeightEnd, range: 0...1)
                    Toggle("Don't squash vertically (keep height)", isOn: $engine.params.coverKeepHeight)
                    ParamSlider("Content shift", value: $engine.params.coverContentShift, range: 0...0.5, format: "%.3f")
                    Toggle("Blur and shading grow toward the hinge (bottom) — off by default: they grow toward the outer edge", isOn: $engine.params.coverTowardHinge)
                }
                Section("Blur / Shading (reference formula)") {
                    ParamSlider("Wipe at full tilt", value: $engine.params.coverWipeAtFullTilt, range: 0...1)
                    ParamSlider("Blur gain", value: $engine.params.coverBlurGain, range: 0...6)
                    ParamSlider("Blur range start", value: $engine.params.coverBlurStart, range: 0...1)
                    ParamSlider("Blur range end", value: $engine.params.coverBlurEnd, range: 0.05...1)
                    ParamSlider("LOD scale", value: $engine.params.coverLodScale, range: 0...12)
                    ParamSlider("Reference texture size (px)", value: $engine.params.coverReferencePx, range: 200...3000, format: "%.0f")
                    ParamSlider("Lowest brightness with blur", value: $engine.params.coverShadeLow, range: 0...1)
                    ParamSlider("Hinge-side darkening gain", value: $engine.params.coverWipeShadeGain, range: 0...6)
                    ParamSlider("Side edge band", value: $engine.params.coverEdgeBand, range: 0.001...0.5, format: "%.3f")
                    ParamSlider("Wipe at which side bands fully appear", value: $engine.params.coverEdgeFadeWipe, range: 0.001...0.5, format: "%.3f")
                }
            }
            Section("Lid Angle → Progress") {
                ParamSlider("Effect start angle", value: $engine.params.openAngle, range: 30...140, format: "%.0f°")
                ParamSlider("Full effect angle", value: $engine.params.closedAngle, range: 0...90, format: "%.0f°")
                ParamSlider("Mapping curve exponent", value: $engine.params.angleCurve, range: 0.3...3)
            }
            if engine.params.style == .gradient {
            Section("Blur") {
                Picker("Direction", selection: $engine.params.direction) {
                    Text("Stronger toward the top (lid edge)").tag(GradientDirection.towardOuterEdge)
                    Text("Stronger toward the bottom (hinge)").tag(GradientDirection.towardHinge)
                }
                Picker("Filter", selection: $engine.params.filter) {
                    Text("Smooth pyramid").tag(BlurFilter.smooth)
                    Text("Mipmap (trilinear)").tag(BlurFilter.mipmap)
                }
                ParamSlider("Max blur (LOD)", value: $engine.params.maxBlur, range: 0...12)
                ParamSlider("Hinge-side blur ratio", value: $engine.params.hingeBlur, range: 0...1)
                ParamSlider("Range start", value: $engine.params.blurStart, range: 0...1)
                ParamSlider("Range end", value: $engine.params.blurEnd, range: 0...1)
                ParamSlider("Spatial curve exponent (pow)", value: $engine.params.blurCurve, range: 0.2...4)
                ParamSlider("Progress base", value: $engine.params.blurBase, range: 0...1)
                ParamSlider("Progress slope", value: $engine.params.blurSlope, range: 0...5)
                ParamSlider("Progress onset", value: $engine.params.blurOnset, range: 0.005...0.5, format: "%.3f")
                Toggle("Scale with screen size", isOn: $engine.params.scaleToPanel)
            }
            Section("Shading") {
                ParamSlider("Overall darkening", value: $engine.params.shadeUniform, range: 0...1.5)
                ParamSlider("Overall darkening curve", value: $engine.params.shadeUniformCurve, range: 0.3...4)
                ParamSlider("Edge darkening", value: $engine.params.shadeEdge, range: 0...1)
                ParamSlider("Edge saturation point", value: $engine.params.shadeEdgeFull, range: 0.05...1)
                ParamSlider("Edge progress curve", value: $engine.params.shadeEdgeCurve, range: 0.3...4)
                ParamSlider("Edge start position", value: $engine.params.shadeStart, range: 0...0.9)
                ParamSlider("Edge spatial curve", value: $engine.params.shadeCurve, range: 0.3...4)
                ParamSlider("Side edge darkening", value: $engine.params.sideShade, range: 0...1)
                ParamSlider("Side edge width", value: $engine.params.sideWidth, range: 0.005...0.3, format: "%.3f")
                ParamSlider("Minimum brightness", value: $engine.params.minShading, range: 0...1)
            }
            }
            Section("Performance") {
                Picker("Max frame rate", selection: $engine.params.maxFrameRate) {
                    Text("60 Hz (saves battery)").tag(60.0)
                    Text("120 Hz (ProMotion)").tag(120.0)
                }
                .pickerStyle(.segmented)
            }
            Section("Smoothing") {
                ParamSlider("lerp (follow input)", value: $engine.params.lerpDrag, range: 0.01...1, format: "%.3f")
                ParamSlider("lerp (fallback animation)", value: $engine.params.lerpSnap, range: 0.01...1, format: "%.3f")
            }
            Section {
                HStack {
                    Button("Reset to Defaults") { engine.params = .default }
                    Spacer()
                    Button("Copy Settings") {
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
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    init(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, format: String = "%.2f") {
        self.title = title; self._value = value; self.range = range; self.format = format
    }

    var body: some View {
        HStack {
            Text(title).frame(width: 230, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}

struct EventLogToggle: View {
    @State private var on = EventLog.shared.enabled
    var body: some View {
        HStack {
            Toggle("Record device measurement log", isOn: $on).onChange(of: on) { _, v in EventLog.shared.enabled = v }
            Spacer()
            Button("Show Log") { if let u = EventLog.shared.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
        }
    }
}

struct LiveStatusRows: View {
    @ObservedObject var status: LiveStatus
    var body: some View {
        LabeledContent("Current angle", value: status.angle.map { String(format: "%.0f°", $0) } ?? "—")
        LabeledContent("Current progress", value: String(format: "%.3f", status.progress))
        LabeledContent("Sensor", value: status.sensorStatus)
        LabeledContent("Capture", value: status.captureStatus)
    }
}
