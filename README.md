# HoverAuction

경매장을 연 상태에서 **가방 아이템 위에 마우스를 올린 채 스페이스**를 누르면 판매 슬롯에 올라가고,
**같은 아이템 위에서 한 번 더** 누르면 등록됩니다. 마우스 클릭이 필요 없습니다.

> Hover a bag item with the Auction House open and tap Space to load it into the sell slot.
> Tap again while still hovering the same item to post it. No mouse clicks needed.

- World of Warcraft Retail (Midnight, Interface `120105` / `120100`)
- 커서가 아이템 위에 없으면 스페이스는 평소대로 **점프**입니다
- 전투 중에는 애드온이 완전히 정지합니다

## 설치

`HoverAuction` 폴더를 통째로 아래 경로에 넣고 `/reload` 하세요.

```
World of Warcraft/_retail_/Interface/AddOns/
```

## 사용법

| 상황 | 스페이스를 누르면 |
|---|---|
| 가방 아이템 호버 | 그 아이템이 판매 슬롯으로 |
| 같은 아이템 위에서 한 번 더 | 등록 |
| 다른 아이템으로 옮긴 뒤 | 그 아이템으로 교체 |
| 커서가 아이템 밖 | 점프 (애드온 관여 없음) |
| 블리자드 경고창이 떠 있을 때 | 수락 |

시세 조회가 끝나기 전에는(최대 1.5초) 등록되지 않습니다. 상인 판매가 기준의 기본값으로
헐값에 올라가는 것을 막기 위한 장치이고, `/ha guard off`로 끌 수 있습니다.

## 설정

```
/ha                  현재 설정 보기
/ha on | /ha off     사용 여부
/ha key SPACE        사용할 키 변경 (예: /ha key E)
/ha qty one | all    등록 수량 방식
/ha guard off        시세 조회 대기 보호 해제
```

`/ha qty all`은 블리자드 판매창의 "최대" 버튼을 대신 눌러주는 방식이라 키를 한 번 더 누르게 됩니다
(올리기 → 최대 → 등록). 수량 입력칸이 뜨지 않는 아이템에서는 이 단계를 건너뜁니다.

## 설계 노트: taint 회피

이 애드온은 **경매장 UI에 쓰기를 하지 않습니다.** 읽기만 합니다.

애드온(비보안 실행)이 `AuctionHouseFrame:SetPostItem()`이나 판매 버튼의 `:Click()`을 직접 호출하면
경매장 UI 상태가 오염(taint)됩니다. 그 뒤 가방 아이템을 우클릭하면
[`ContainerFrame.lua`](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_UIPanels_Game/Mainline/ContainerFrame.lua)가
오염된 경매장 상태를 읽은 다음 보호된 함수 `UseContainerItem()`을 호출하면서 차단됩니다.

```
[ADDON_ACTION_FORBIDDEN] 'HoverAuction' ... 'UseContainerItem()'
```

그래서 이 애드온은 `SecureActionButtonTemplate`의 `type="click"` 위임으로
**무엇을 클릭할지만 지정**하고, 실제 클릭은 블리자드 코드가 보안 실행에서 직접 수행합니다.

- 가방 버튼 ← 우클릭 위임 (블리자드가 `SetPostItem`을 호출)
- 등록 버튼 / "최대" 버튼 / 경고창 수락 버튼 ← 좌클릭 위임

키 바인딩 관리도 전부 보안 핸들러 스니펫이 맡습니다. 전투 중에는 애드온 코드가 바인딩 API를
호출할 수 없기 때문입니다. 덕분에 전투가 시작되면 스니펫이 즉시 바인딩을 풀어 스페이스를 점프로 돌려줍니다.

참고로 `SecureHandlerStateTemplate`은 이름이 `state-`로 시작하는 속성이 바뀔 때만
대응하는 `_onstate-<이름>` 스니펫을 실행합니다. 일반 속성에 반응하는 `_onattributechanged`는
`SecureHandlerAttributeTemplate` 쪽 기능이라 이 템플릿에서는 동작하지 않습니다.

## 라이선스

[MIT](LICENSE)
