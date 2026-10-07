# Test plan ng uploading (PEKENG data lang)

Lahat ng `FAKE_*.xlsx` dito ay gawa-gawang data. **Huwag maglagay ng tunay na file sa folder na ito.**
Lahat ng claim series ay pekeng numero (edge set: `26…`, volume set: `30…`).

Bago magsimula: i-refresh ang app (`Ctrl+F5`). Gamitin ang:
- Facility Admin ng TEST-HOSP-0001 para sa HF ICS (Upload Claims)
- FINMAREP para sa extractions (Data Ingestion), sa run ng **TEST-HOSP-0001 (Sample General Hospital)**

---

## A. Edge cases (maliit, mabilis)

### A1. `FAKE_EDGE_hf_ics_TEST-HOSP-0001.xlsx` → Upload Claims

| Tingnan | Inaasahan |
|---|---|
| Sheet na awtomatikong napili | **ICS** (hindi "Notes", kahit nauna ito) |
| Header row | **8** |
| Claim Series column | B · CLAIM SERIES NO. |
| ICS amount column | H · ICS AMOUNT |
| Rows with data | **35** (34 claim + TOTAL; ang blangkong row sa gitna ay nilalaktawan) |
| Invalid Claim Series | **3** (item 16 "12345", item 17 blangko, TOTAL) |
| Total ICS amount | **1,332,031.78** (kasama ang TOTAL row, kaya doble) |

Preview at resulta sa DB (ako ang magche-check):
| Item | Nasa file | Dapat maging |
|---|---|---|
| 11 | `0001234567011` (text) | `0001234567011` (hindi nawala ang zeros) |
| 12 | number na `2610000001212` (sa Excel: `2.61E+12`) | `2610000001212` |
| 13 | `26-1000-0001313` | `2610000001313` |
| 14 | `  2610000001414 ` | `2610000001414` |
| 15 | `261000000151507` (15 digits) | `2610000001515` |
| 18 | `₱ 12,345.67` | 12345.67 |
| 19 | `(1,000.00)` | -1000.00 |
| 24 | parehong series ng item 5 | tinatanggap (duplicate; sa matching ito ifa-flag) |

### A2. `FAKE_EDGE_extractions_TEST-HOSP-0001.xlsx` → Data Ingestion (4 slot)

| Slot | Sheet | Header row | Rows | Unreadable dates/numbers |
|---|---|---|---|---|
| HO ICS | HO ICS | **3** | **21** | **1** (RECREF "13/45/2024") |
| Raw Matching | 1. RAW-DATA MATCHING | **3** | **34** | **1** (DATE_ADM "02/31/2025") |
| Status Trail | 2. STATUS TRAIL | **1** | **99** | **1** (TIME_REC "N/A") |
| Payment Details | 4. PAYMENT DETAILS | **1** | **8** | 0 |

Lahat ng column ay dapat awtomatikong naka-map. Ang "CLAIM IS PART OF ICS?" at "ICS?" ay hindi naka-map (formula sa Excel; itinatabi lang).

### A3. `FAKE_EDGE_yugto2_TEST-HOSP-0001.xlsx` → Data Ingestion, "Additional details (optional)" (7 slot)

Sa **parehong run** ng A2 (EDGE). Kung "matched" na ang run: sa Reconciliation, pindutin ang **Reopen**, i-upload ang 7 file,
tapos **Run matching** ulit. Iisang file ang ia-upload sa bawat slot; dapat awtomatikong mapili ang tamang sheet.

| Slot | Sheet | Header row | Rows | Invalid series | Unreadable or flagged |
|---|---|---|---|---|---|
| RTH/Denial Reasons | 5. Reasons for RTH and Denial | **1** | **6** | 0 | 0 |
| Motion for Reconsideration | 6. Motion for Reconsideration | **3** | **4** | 0 | **1** (mrRcvDate "02/30/2025") |
| PARD | 7. PARD | 1 | **3** | 0 | 0 |
| PF Name | 8. PF Name | 1 | **6** | **1** ("12345") | 0 |
| Tagging of Issue | 9. Tagging of Issue | 1 | **3** | 0 | 0 |
| Untagging of Issue | 10. Untagging of Issue | 1 | **1** | 0 | 0 |
| ICD Codes | 11. ICD Codes | 1 | **5** | 0 | **2** (row ng `2610000001313`: ICDCODE "12500" at amount "K35.8" — nagkapalit, Open Question #3) |

Sa RTH sheet: ang blangkong column (B) at ang table sa kanan (I–J) ay hindi naka-map; itinatabi lang.

**Pagkatapos ng matching — Matching Report (inaasahan):**

| Item | Claim series | Inaasahan |
|---|---|---|
| 1 | 2610000000101 | Case rate: **J18.9 / 99999 \| A09** · HCP: **DR. ANA SAMPLE; DR. JUAN FAKE** (walang ulit) · Internal: Tag **POLICY ISSUE Y (TEST)** (04/01/2025), Untag **RESOLVED (TEST)** (03/15/2025) |
| 2 | 2610000000202 | Case rate: **N18.5 / 90935** (walang second) · HCP: **DR. PEDRO TEST** |
| 5 at 24 | 2610000000505 (item 24 = DUPLICATE) | HCP: **DR. MARIA DEMO** sa pareho · Internal: Tag **SYSTEM ISSUE Z (TEST)** (03/10/2025), walang untag |
| 9 | 2610000000909 | History effect **D** (huling row) · MR **GRANTED** (rcv 05/01/2025, decision 06/01/2025) · PARD **PARD APPROVED (TEST)** (07/01/2025) |
| 11 | 0001234567011 | History effect **P** (blangko ang huling row, kaya ang naunang may laman) · MR **PENDING**, walang rcv date |
| 13 | 2610000001313 | Case rate: **12500 / 44950** (galing sa nagkapalit na row — makikita ang problema ng #3) |
| 22 | 2610000002222 | History effect **P** · PARD **PARD DENIED (TEST)** (08/15/2025) |

- Ang MR ng `2610000009999` ay wala sa HF ICS → hindi lalabas sa report, pero makikita sa Claim History kung hahanapin.
- **Facility view** (`f_reports.html`, Facility Admin ng TEST-HOSP-0001): nakikita ang case rate, HCP, history effect, MR, PARD;
  **walang** Tag/Untag column. Sa Excel export ng facility: walang grupong "INTERNAL DATA ONLY".
- **Claim History** (FINMAREP / BAS, button na "History" sa item 9): dapat may Raw Matching, Status Trail, HO ICS (kung meron),
  2 RTH/Denial Reason, 2 MR, 2 PARD — pinakabago muna.

---

### A4. `FAKE_EDGE_claim_type_TEST-HOSP-0001.xlsx` → slot na "Type of Claim (eClaims / Manual)"

Sheet **12. Type of Claim**, header row **1**, **6** rows, **1** invalid series ("12345"). Pagkatapos ng matching
(Internal Data Only → "Type of claim"):

| Item | Claim series | Inaasahan |
|---|---|---|
| 3 | 2610000000303 | eClaims |
| 9 | 2610000000909 | **eClaims** (pinakabagong row; ang naunang "Manual" ay hindi gagamitin) |
| 11 | 0001234567011 | Manual |
| 12 | 2610000001212 | eClaims |

Makikita rin sa Claim History ng item 9 ang dalawang "Type of Claim" row.

Kasama rin sa parehong matching (walang bagong file na kailangan):
- **Filed vs actual payment upgrade** — may halaga lang sa PAID, APPROVED FOR PAYMENT at IN PROCESS (= Recon amount − ICS amount);
  blangko sa DENIED, RTH, UNMATCHED, DUPLICATE.
- **Payment TAT** — sa mga PAID (item 3, 6, 12, 15, 21): araw mula filing hanggang check date (walang issue sa EDGE data).
- Sa ICD Codes upload: lalabas sa ilalim ng mga bilang ang listahang "Please double-check these values" (row ng `2610000001313`).

---

## B0. Volume 50k (kasya sa Free plan na 500 MB)

Ang 200k set (B) ay ~685 MB bawat test — hindi kakasya sa Free plan. Gamitin muna ito:

| File | Slot | Rows | Header row |
|---|---|---|---|
| `FAKE_VOL50K_hf_ics.xlsx` | Upload Claims (facility) | **50,000** | 8 |
| `FAKE_VOL50K_raw_matching.xlsx` | Raw Matching | **49,000** | 1 |
| `FAKE_VOL50K_status_trail.xlsx` | Status Trail | **98,000** | 1 |
| `FAKE_VOL50K_ho_ics.xlsx` | HO ICS | **42,858** | 1 |
| `FAKE_VOL50K_payment_details.xlsx` | Payment Details | **19,394** | 1 |

Inaasahan: 1,000 UNMATCHED (bawat ika-50), 0 invalid; balanse ang Annex A (claims at amount) sa internal at facility.

**Isabay ang Yugto 2 sa parehong run BAGO mag-Run matching** (isang matching lang para sa lahat):
`FAKE_VOL50K_yugto2.xlsx` — iisang file, i-upload sa bawat isa sa 8 slot ng "Additional details (optional)".
Kung na-match na ang run: Reopen → upload → Run matching ulit.

| Slot | Sheet | Rows |
|---|---|---|
| RTH/Denial Reasons | 5. Reasons for RTH and Denial | 13,859 |
| Motion for Reconsideration | 6. Motion for Reconsideration (header row 3) | 5,444 |
| PARD | 7. PARD | 1,000 |
| PF Name | 8. PF Name | 61,000 |
| Tagging of Issue | 9. Tagging of Issue | 2,000 |
| Untagging of Issue | 10. Untagging of Issue | 1,000 |
| ICD Codes | 11. ICD Codes | 65,333 |
| Type of Claim | 12. Type of Claim | 49,000 |

Inaasahan pagkatapos ng matching: History Effect sa lahat ng RTH (3,960) at DENIED (5,444); MR sa lahat ng DENIED; PARD sa 1,000;
case rate at HCP sa lahat ng 49,000 na nasa universe; Issue sa 2,000 (1,000 OPEN, 1,000 RESOLVED); Type of Claim sa 49,000.

## B. Volume (malaki; para sa bilis at memory)

Una ang HF ICS (bilang facility), tapos gumawa ng **bagong run** para sa TEST-HOSP-0001 at piliin ang 200k na HF ICS sa dropdown.

| File | Slot | Rows | Header row |
|---|---|---|---|
| `FAKE_VOLUME_hf_ics_200k.xlsx` | Upload Claims (facility) | **200,000** | 8 |
| `FAKE_VOLUME_raw_matching_200k.xlsx` | Raw Matching | **196,000** | 1 |
| `FAKE_VOLUME_status_trail_392k.xlsx` | Status Trail | **392,000** | 1 |
| `FAKE_VOLUME_ho_ics_171k.xlsx` | HO ICS | **171,429** | 1 |
| `FAKE_VOLUME_payment_details.xlsx` | Payment Details | **77,576** | 1 |

Itala para sa bawat isa:
1. Ilang segundo bago lumabas ang preview pagkapili ng file.
2. Ilang minuto ang upload hanggang 100%.
3. Kung bumagal o nag-hang ang browser (at kung may error, ang eksaktong mensahe).

Lahat ng volume file ay dapat **0 invalid** at **0 unreadable**.

---

## Pagkatapos ng bawat upload
Itala kung aling file ang na-upload at i-check sa database ang bilang ng row, ang normalization ng
claim series, ang mga petsa at halaga, at ang mga flag.
