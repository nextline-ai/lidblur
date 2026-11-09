# LidBlur 앱 아이콘

`make_icon.py`가 Icon Composer용 레이어를 만듭니다(1024×1024, 투명 배경). 다시 만들려면:

```
python3 make_icon.py   # numpy, pillow 필요
```

## 레이어 (아래 → 위)

| 레이어 | 파일 | 비고 |
|---|---|---|
| Background | `Layers/Background.svg` (또는 `.png`) | 남색 그라디언트 + 화면 뒤 은은한 보라 빛 |
| Screen | `Layers/Screen.png` | 직사각형 디스플레이(베젤) 안에서 화면 내용만 사다리꼴로 기움. 위쪽과 좌우 가장자리로 갈수록 흐려지고 어두워짐. 블러가 들어 있어 PNG만 제공 |
| Base | `Layers/Base.svg` (또는 `.png`) | 정면에서 본 키보드 데크(알루미늄)와 가운데 홈 |

## Icon Composer 권장 설정

- 세 레이어를 위 순서대로 넣습니다. 배경은 Background 레이어를 쓰거나 Fill을 같은 그라디언트로 지정합니다.
- Screen 레이어는 이미 블러와 음영이 들어 있습니다. Composer의 Blur는 끄고, Specular만 약하게 두는 것을 권장합니다.
- Base 레이어는 Specular를 켜면 알루미늄 질감이 살아납니다.
- 다크/틴트 모드는 Composer의 자동 변환을 기본으로 쓰고, 필요하면 Background만 더 어둡게 조정합니다.

`Preview-masked.png`, `Preview-sizes.png`는 확인용 미리보기입니다. 실제 아이콘 모양(마스크)은 Icon Composer가 적용합니다.
