# EQ Might: 旧ヒール閾値 ↔ 新 Class Heal 対応表

対象: `rgmercs-kesh` の **EQ Might** CLR / PAL / DRU / SHM。  
根拠: 本家 `lua/rgmercs`（ポイント制）と現行 `lua/rgmercs-kesh/class_configs/EQ Might/*_class_config.lua`（Class Heal）。  
更新: 2026-08-27 — **Class Heal: Big Heal は廃止。旧 Big 帯は Fast Heal に統合。**

---

## 1. 比較演算子（ここを外すと「同じ数字」でも挙動がずれる）

| 系 | 判定 | ソース |
|----|------|--------|
| **旧** `Targeting.BigHealsNeeded` / `MainHealsNeeded` / `LightHealsNeeded` | `PctHPs < 設定値` | `rgmercs/utils/targeting.lua` |
| **旧** `GroupHealsNeeded` | `Group.Injured(GroupHealPoint) >= GroupInjureCnt`（MQ TLO。Injured は通常 **未満**） | 同上 |
| **旧** `BigGroupHealsNeeded` | `Group.Injured(BigHealPoint) >= GroupInjureCnt` | 同上 |
| **旧** 対象スキャン `FindWorstHurtGroupMember(minHPs)` | `PctHPs < minHPs` | `utils/combat.lua` |
| **新** `Helpers.ClassBelow(kind, target)` | `PctHPs <= HealPct{kind}_{Role|CLASS}`。**0 は無効** | 各 class_config |
| **新** グループ判定 | `ClassBelow` を満たす人数 `>= GroupInjureCnt` | 各 class_config |

したがって旧 `BigHealPoint = 50` と新 `HealPctFastHeal_* = 50` は **同じ数字でも一致しない**。  
- 旧: HP **49 以下**で Big（HP=50 では Big に入らない）  
- 新: HP **50 以下**で Fast  

旧と厳密に揃えるなら新側を **旧値 − 1** にする（例: 旧 50 → 新 49）。逆に「設定値ちょうどでも発動してよい」なら数字をそのまま写してよい。

---

## 2. 設定キー対応（グローバル → クラス別）

旧は **全クラス共通の1本**。新は **対象ロールごとに1本**（CLR/PAL/DRU/SHM: `HealPct{Kind}_{Tank|Melee|Caster}`）。

| 旧設定（`utils/config.lua` 既定） | 新 kind / 設定プレフィックス | 意味の対応 |
|----------------------------------|------------------------------|------------|
| `BigHealPoint` **Default = 50** | `FastHeal` → `HealPctFastHeal_*` | 旧 Big 回転帯（AA・クリック・Remedy/Burst 等） |
| `MainHealPoint` **Default = 80** | `Light` → `HealPctLight_*`（UI名 Regular Heal） | 旧 Main 回転の通常ヒール帯 |
| `GroupHealPoint` **Default = 80** | `GroupHeal` → `HealPctGroupHeal_*`（UI名 Group Regular Heal）※SHM は無し（下記） | 旧 Group 回転の人数ゲート |
| `LightHealPoint` **Default = CLR 95 / 他 90** | （直接対応なし） | この4クラスのヒール回転では旧でも未使用。新スキャンは全 `HealPct*` の最大 |
| `MaxHealPoint` **Default = 90** | **廃止** → `Class:GetHealScanThreshold()` = 設定済み `HealPct*` の最大（全0なら 100） | 誰をヒール対象にするかのゲート |
| `CompleteHealPct` **Default = 80**（CLR のみ） | `CompleteHeal` → CLR は `HealPctCompleteHeal_Tank` のみ | タンク CH 専用 |
| `PetHealPoint` **Default = 50** | **据え置き**（SHM `Companion's Blessing` 等） | Class Heal に含めない |
| `GroupInjureCnt` **Default = 3** | **据え置き** | グループ人数条件 |
| `HPCritical` **Default = Tank 20 / 他 30** | **据え置き**（PAL Lay on Hands / Hand of Piety の追加条件） | Fast 帯とは別ゲート |
| （なし） | `SingleHoT` / `GroupHoT` | 旧は Main/Group 回転にぶら下がり、独立 % は無し |
| ~~`HealPctBigHeal_*`~~ | **廃止** | 旧 kesh 一時実装。現コードは読まない |

### 旧値を全クラス同じ数字で移植する手順（厳密）

1. 旧設定値を読む: `BigHealPoint`, `MainHealPoint`, `GroupHealPoint`, （CLR）`CompleteHealPct`。  
2. 比較を揃えるなら各値から 1 引く（§1）。  
3. 全対象クラスの該当 `HealPct*` に同じ数字を入れる（`BigHealPoint` → **FastHeal**）。  
4. スキャンは自動で最大値になる。旧 `MaxHealPoint` は無視される。  
5. SingleHoT / GroupHoT は旧に独立値が無い → 下記クラス節。

### コード既定値の注意

| クラス | `defaultHealPct` |
|--------|------------------|
| **CLR** | ロール別。CompleteHeal(Tank)=80, FastHeal Tank=45/他0, Light=65, GroupHeal=64, SingleHoT Tank=95/他0, GroupHoT=0 |
| **PAL** | FastHeal Tank=45/他0, Light=65, GroupHeal=64, SingleHoT Tank=95/他0（CLR と同値） |
| **DRU** | FastHeal Tank=45/他0, Light=65, GroupHeal=64（CLR と同値） |
| **SHM** | FastHeal Tank=45/他0, Light=65, SingleHoT Tank=95/他0, GroupHoT=0（CLR と同値） |

「コードの Default」と「旧ポイントの Default を写した値」は別物。PAL/DRU/SHM は未設定のままではヒールしない。

---

## 3. CLR

### 3.0 ロール（2026-09-03〜）— CLR / PAL / DRU / SHM 共通

| ロール | 対象クラス | 設定キー例 |
|--------|------------|------------|
| **Tank** | WAR / SHD / PAL | `HealPctLight_Tank` |
| **Melee** | RNG / MNK / ROG / BER / BST / BRD | `HealPctLight_Melee` |
| **Caster** | CLR / DRU / SHM / NEC / WIZ / MAG / ENC / OTH | `HealPctLight_Caster` |

Complete Heal（CLR）は **`HealPctCompleteHeal_Tank` のみ**。  
旧 `HealPct*_{CLASS}` は起動時に代表値へ移行（Tank←WAR…、Melee←MNK…、Caster←WIZ…）。

### 3.1 旧回転構造（本家 EQ Might CLR）

| 旧回転 | 入場条件 |
|--------|----------|
| `GroupHeal` | `GroupHealsNeeded()` |
| `BigHeal` | `BigHealsNeeded(target)` かつ pet でない |
| `MainHeal` | `MainHealsNeeded(target)` |

### 3.2 アビリティ対応（旧回転 → 新 `heal_kind`）

| アビリティ | 旧 | 新 `heal_kind` | 備考 |
|-----------|----|----------------|------|
| Divine Arbitration | BigHeal | **FastHeal** | |
| Sanctuary | BigHeal | **FastHeal** | |
| Burst of Life | BigHeal | **FastHeal** | |
| Epic | BigHeal | **FastHeal** | |
| Focused Celestial Regeneration | BigHeal | **FastHeal** | |
| Blessing of Sanctuary | BigHeal | **FastHeal** | |
| Celestial Rapidity | BigHeal | **FastHeal** | |
| Forceful Rejuvenation | BigHeal | **FastHeal** | |
| RemedyHeal | BigHeal（Renewal と一本） | **FastHeal** | |
| Renewal | BigHeal（Remedy と一本） | **Light** | 意図的に Regular。旧と同入場にしたいなら Fast へ戻す |
| Eternal Recovery | BigHeal | **（現行リストに無し）** | |
| Timer2HealItem / Braided Kirin Mane（Big 枠・無条件） | BigHeal | **削除**（mana&lt;10 の panic 枠のみ） | |
| HealingLight | MainHeal | **Light** | |
| CompleteHeal | MainHeal + `CompleteHealPct` + tank | **CompleteHeal** | WAR/PAL/SHD のみ |
| SingleElixir | MainHeal + not Big | **SingleHoT** | |
| Beacon of Life / GroupHeal スペル / BlueBand 類 / Exquisite Benediction | GroupHeal | **GroupHeal** | Celestial Regen の旧「対象 Big」追加条件は無し |
| GroupElixir | GroupHeal + HP &gt; BigHealPoint | **GroupHoT** | |

### 3.3 CLR 閾値の写し方

| 旧 | 新へ |
|----|------|
| `BigHealPoint` | 全クラス `HealPctFastHeal_*` |
| `MainHealPoint` | `HealPctLight_*`（Healing Light / Renewal） |
| `CompleteHealPct` | `HealPctCompleteHeal_WAR/PAL/SHD` |
| `GroupHealPoint` | `HealPctGroupHeal_*` |
| SingleElixir | `HealPctSingleHoT_*` |
| GroupElixir | `HealPctGroupHoT_*` |

---

## 4. PAL

### 4.1 アビリティ対応

| アビリティ | 旧 | 新 `heal_kind` | 備考 |
|-----------|----|----------------|------|
| Lay on Hands | BigHeal + Combat + `HPCritical` | **FastHeal** + 同条件 | |
| Eternal Recovery / Marr's Gift | BigHeal | **FastHeal** | |
| Hand of Piety（緊急） | BigHeal | **FastHeal** | |
| BurstHeal | BigHeal | **FastHeal** | |
| VampiricBlueBand / BlueBand | **BigHeal** | **GroupHeal** | 帯変更あり |
| Hand of Piety（グループ）/ Act of Valor / Wave / Mantle | GroupHeal | **GroupHeal** | 旧 BigGroup 追加条件は無し |
| Cleansing | Main + not Big | **SingleHoT** | |
| LightHeal / LightHeal2 / TouchHeal | MainHeal | **Light** | |

### 4.2 PAL 閾値の写し方

| 旧 | 新へ |
|----|------|
| `BigHealPoint` | `HealPctFastHeal_*` |
| `MainHealPoint` | `HealPctLight_*` |
| `GroupHealPoint` | `HealPctGroupHeal_*` |
| Cleansing | `HealPctSingleHoT_*` |

コード既定: 全 `HealPct*` = **0**。

---

## 5. DRU

| アビリティ | 旧 | 新 `heal_kind` |
|-----------|----|----------------|
| SnareHot / Balance of the Grove / Eternal Recovery / Convergence / Timer2 / Mask（Big） | BigHealPoint | **FastHeal** |
| BlueBand 類 / GroupHeal スペル | GroupHealPoint | **GroupHeal** |
| HealSpell | MainHealPoint | **Light** |

| 旧 | 新へ |
|----|------|
| `BigHealPoint` | `HealPctFastHeal_*` |
| `MainHealPoint` | `HealPctLight_*` |
| `GroupHealPoint` | `HealPctGroupHeal_*` |

コード既定: 全 **0**。

---

## 6. SHM

| アビリティ | 旧 | 新 `heal_kind` | 備考 |
|-----------|----|----------------|------|
| Call of the Ancients | Group + 対象 Big | **FastHeal** | 新は Fast のみ |
| SnareHot / Eternal / Ancestral Guard / Timer2 / Mark / Union / Forceful Rejuv | BigHealPoint | **FastHeal** | |
| GroupRenewalHoT / BlueBand 類 | GroupHealPoint | **GroupHoT** | SHM に Group Regular kind 無し |
| SingleHot | Main + not Big | **SingleHoT** | |
| HealSpell | MainHealPoint | **Light** | |
| Companion's Blessing | `PetHealPoint` | **`PetHealPoint` のまま** | |

| 旧 | 新へ |
|----|------|
| `BigHealPoint` | `HealPctFastHeal_*` |
| `MainHealPoint` | `HealPctLight_*` |
| `GroupHealPoint` | **`HealPctGroupHoT_*`** |
| SingleHot | `HealPctSingleHoT_*` |

コード既定: 全 Class Heal **0**。

---

## 7. 旧に無く新にあるもの / 差分

| | |
|--|--|
| 新のみ | クラス別 %。独立 HoT %。Renewal を Regular に分離（CLR） |
| 廃止（kesh） | `Class Heal: Big Heal` / `HealPctBigHeal_*` → Fast に統合 |
| 旧のみ（設定） | `MaxHealPoint`、Class Heal 使用時 UI 非表示の Light/Main/Big/GroupHealPoint |
| 挙動差 | グループ対象選定のタンク優先は `TankPriorityThreshold`（旧は `MainHealPoint`）。0＝優先なし |
| 挙動差 | 旧 Group 内の「さらに Big 人数 / 対象 Big」条件の一部は新で落ちている |

---

## 8. 早見（設定だけ）

```
旧 BigHealPoint     → HealPctFastHeal_*         （CLR 既定50 / 他クラスコード既定0）
旧 MainHealPoint    → HealPctLight_*
旧 GroupHealPoint   → HealPctGroupHeal_*        （SHM だけ → HealPctGroupHoT_*）
旧 CompleteHealPct  → HealPctCompleteHeal_{WAR,PAL,SHD}   （CLRのみ）
旧 MaxHealPoint     → （廃止） max(HealPct*)
旧 LightHealPoint   → この4クラスのヒール回転では未使用
旧 PetHealPoint     → PetHealPoint のまま
（新）SingleHoT     ← 旧 Main 内 HoT
（新）GroupHoT      ← 旧 Group 内 Elixir/Renewal 系（CLR/SHM）
（廃止）HealPctBigHeal_*  ← 使わない。旧 Big 相当は Fast
```

アビリティ単位の最終確認は必ず当該 `class_configs/EQ Might/{clr,pal,dru,shm}_class_config.lua` の `heal_kind` を見ること。本ファイルとコードが食い違う場合は **コードが正**。
