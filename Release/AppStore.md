# App Store 제출 자료 — LidBlur 1.0.0

- 번들 ID: `work.nextline.lidblur`
- 팀: daeummoyang (6HV24C77H5)
- 카테고리: 유틸리티
- 가격: 무료
- 최소 macOS: 15.0
- 지원 언어: 한국어, 영어 (앱 내 문자열은 `Shared/Localizable.xcstrings`)
- 개발: NextLine (nextline.work)
- 배포: DEAUM (deaum.org)

> 메타데이터에 "iPhone", "iPhone Duo", "Apple"을 쓰지 마세요. 상표 문제로 심사 반려 사유(가이드라인 2.3.7, 5.2.5)가 됩니다.
> "폴더블 기기처럼"이라고만 표현합니다.

## 한국어

**이름** (30자 이내)
LidBlur

**부제** (30자 이내)
덮개를 닫으면 화면이 접히듯 흐려짐

**홍보 문구** (170자 이내)
맥북 덮개를 천천히 닫아 보세요. 화면이 접히는 패널처럼 기울며 흐려지고 어두워지다가, 다시 열면 또렷하게 돌아옵니다.

**설명**
LidBlur는 맥북 덮개를 닫고 여는 순간을 폴더블 기기처럼 바꿔 줍니다.

덮개를 내리면 화면이 접히는 패널처럼 사다리꼴로 기울면서 바깥쪽 끝부터 부드럽게 흐려지고 어두워집니다. 덮개를 다시 열면 같은 길을 되짚어 또렷한 화면으로 돌아옵니다. 효과는 맥북에 내장된 덮개 각도 센서를 실시간으로 따라가므로, 손으로 덮개를 멈추면 효과도 그 자리에 멈춥니다.

• 덮개 각도에 맞춰 실시간으로 움직이는 기울기·블러·음영
• 원근이 살아 있는 사다리꼴 변형과 부드러운 단계별 블러
• 효과가 필요 없을 때는 거의 자원을 쓰지 않는 저전력 설계
• 화면 내용은 기기 안에서만 처리하며, 어디에도 저장하거나 보내지 않음
• 시작 각도, 최대 기울기, 블러·음영 세기를 원하는 대로 조정
• 메뉴 막대에서 켜고 끄기, 로그인 시 자동 실행

덮개 각도 센서가 있는 맥북에서 실시간으로 동작합니다. 센서가 없는 맥에서는 덮개를 열 때 시간 기반 애니메이션으로 대신합니다.

화면에 효과를 그리려면 '화면 및 시스템 오디오 기록' 권한이 필요합니다. 처음 실행할 때 안내 창이 설정을 도와 줍니다.

개발: NextLine · 배포: DEAUM

**키워드** (100자 이내, 쉼표 구분)
덮개,노트북,폴더블,블러,접기,힌지,각도,화면효과,애니메이션,메뉴막대,맥북,디스플레이

## English

**Name**
LidBlur

**Subtitle** (≤30)
A foldable look for your lid

**Promotional text** (≤170)
Close your MacBook slowly. The screen tilts like a folding panel, blurring and dimming as it goes — and clears again when you open it.

**Description**
LidBlur turns closing and opening your MacBook into a foldable-device moment.

As the lid comes down, the screen tilts like a folding panel, softly blurring and dimming from its outer edge. Open it again and the picture retraces its path back to sharp. The effect follows your MacBook's built-in lid angle sensor in real time, so if you stop the lid, the effect stops with it.

• Tilt, blur and shading that follow the lid angle live
• Perspective-correct trapezoid with smooth, progressive blur
• Low power: next to no work while the effect is not needed
• Screen content is processed on device only, never stored or sent anywhere
• Adjust the start angle, maximum tilt, blur and shading
• Toggle from the menu bar; optional launch at login

Works in real time on MacBooks with a lid angle sensor. On Macs without one, an opening animation plays when you lift the lid.

LidBlur needs the Screen & System Audio Recording permission to draw the effect. A short setup guide helps on first launch.

Developed by NextLine · Distributed by DEAUM

**Keywords** (≤100)
lid,laptop,foldable,blur,fold,hinge,angle,screen effect,animation,menu bar,display,close

## 심사 메모 (App Review Notes, 영어로 제출)

LidBlur is a menu bar utility. When the MacBook lid is lowered, it draws a full-screen, click-through overlay on the built-in display. The overlay shows the current screen content tilted, blurred and dimmed according to the lid angle, and it disappears when the lid is open.

How to test:
1. Launch LidBlur. The setup window asks for Screen & System Audio Recording permission. Grant it and relaunch if macOS asks.
2. Slowly lower the lid below about 95°: the screen tilts, blurs and dims. Raise it again and the effect clears.
3. To test without moving the lid: menu bar icon → "Tuning / About…" → set Input to "Debug slider", then move "Debug progress".

Entitlements:
- com.apple.security.device.usb: needed to read the built-in lid angle sensor. It is a HID sensor device, read with IOKit HID (IOHIDDeviceGetReport). Nothing else is accessed, and the device is opened read-only.
- Screen recording (ScreenCaptureKit): used only to render the effect. Frames stay in GPU memory, are never written to disk and never leave the device. The app has no network code.

The overlay window ignores mouse events and never takes focus. It is not shown on the lock screen.

## 제출 전 남은 일 (사용자)

- [ ] App Store Connect에서 앱 레코드 생성: 번들 ID `work.nextline.lidblur`, 이름 LidBlur, SKU 예: `lidblur-mac`
- [x] 개인정보 처리방침 URL: https://nextline-ai.github.io/lidblur/privacy/ (원본 `docs/privacy.md`)
- [x] 지원 URL: https://nextline-ai.github.io/lidblur/ (원본 `docs/index.md`)
- [ ] 스크린샷 준비: 16:10 비율, 1280×800 이상(권장 2880×1800), 1–10장
- [ ] 앱 개인정보(App Privacy) 설문: "데이터를 수집하지 않음"
- [ ] 연령 등급: 4+
- [ ] 업로드: `Release/build-appstore.sh`로 아카이브 → Xcode Organizer 또는 Transporter로 업로드
