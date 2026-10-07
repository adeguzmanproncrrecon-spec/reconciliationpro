# ReconciliationPro – System Specification (mula sa Excel reconciliation workbook)

Layunin: palitan ang Excel reconciliation workbook (hal. "NCR NORTH – AS OF <DATE> – <HOSPITAL>.xlsx").
Mag-a-upload ang staff ng raw extractions; ang system ang gagawa ng Matching Report, reconciling items, at Annex A.
Isang workbook = isang **reconciliation run** para sa isang facility, may **Report Date (cutoff)** at **Matching Date**.

---

## 1. Universal rules

- **Matching key:** Claim Series. Normalize: tanggalin ang lahat ng non-digit, kunin ang unang 13 digits
  (`left(regexp_replace(x,'\D','','g'),13)`). Kulang sa 13 o blangko → "Invalid Claim Series", hindi ima-match.
- Laging basahin ang Claim Series bilang **text** (iwas scientific notation).
- **Petsa:** tanggapin ang Excel serial number (hal. `46234`), `MM/DD/YYYY`, at datetime; i-save bilang `date`.
- Blangko / `-` / `00:00:00` → `NULL`.
- Mga pangalan: uppercase, trim, isang space lang; `N/A` → NULL.
- Lahat ng matching ay sa SQL/RPC. 200k+ rows bawat upload: batch insert, pagination, walang full load sa browser.
- Ang mga manual na hakbang sa Excel ("sort first before pasting", "keep text only", "change blanks to '-'") ay
  awtomatiko na sa system.

---

## 2. Inputs (uploads bawat run)

### Yugto 1 – Core
| Upload | Pinanggalingan | Mahahalagang columns |
|---|---|---|
| **HF ICS** | Facility submission (sheet "ICS", headers row 8) | Claim Series LHIO (15 digits → 13), ICS amount, statuses, dates |
| **HO ICS** | Libro ng PhilHealth | CLAIM_SERIES, ESTIMATED_AMT, RECREF date |
| **Raw Matching (Claims Universe)** | PhilHealth extraction | PH_INST_CODE, SERIES, MECNO, PATLNAME, PATFNAME, PATMNAME, WORLNAME, WORFNAME, WORMNAME, DATE_ADM, DATE_DIS, DATE_REC, DATE_RECON, LAST_REFILED, STATUS (G/D/P), TOTAL_ACR_AMOUNT, LATEST_CHECK_DT, TOTAL_TOT_AMNT, LATEST_CTRL_NO, LATEST_CTRL_DT |
| **Status Trail** | PhilHealth extraction (maaaring maraming upload) | SERIES, TIME_REC, DATE_TAGGED, PROCESS |
| **Payment Details** | PhilHealth extraction | SERIES, DATE_EXT, CHECK_NO, CHECK_DT, ISIRM, IS_DCPM, PR_NO, TRANCHE_NUMBER, CW_TAX, RECEIPT_NO, RECEIPT_DT, CPAY_TO, TOTAL_TOT_AMNT |

### Yugto 2 – Dagdag na detalye
| Upload | Columns |
|---|---|
| RTH/Denial Reasons | CLAIM SERIES, DEF CODE, REASON, EFFECT |
| Motion for Reconsideration | SERIES, hciPAN, memberPIN, mrRcvDate, approval, finalRecom, finalBasis, dateFinalized, uploadedDate, crcReceivedDate, iniDateEncoded, finalDateEncoded |
| PARD | SERIES, ENTRY_DATE, APPROVAL_SOURCE |
| PF Name | SERIES, DOCTORS NAME |
| Tagging of Issue | SERIES, DATE_TAGGED, PROCESS |
| Untagging of Issue | SERIES, DATE_UNTAGGED, PROCESS |
| ICD Codes | SERIES, ICDCODE, RVSCODE, TOTAL_ACR_AMOUNT (tingnan ang Open Questions: mukhang nagkapalit ang headers at data) |

Iba-iba ang format ng raw extractions → **column mapping profiles** (auto-detect headers, i-confirm ng user, i-save para sa susunod).

**Mga desisyon sa uploads (2026-10-05):**
- Format: **Excel (.xlsx)**.
- **Petsa: laging MM/DD/YYYY.** Sa pag-parse, tanggapin din ang Excel date serial (karaniwang ganito naka-store ang petsa kahit MM/DD/YYYY ang display); huwag gamitin ang locale ng browser.
- **Claim Series: 13 digits** (normalize ayon sa docs/DEVELOPER_NOTES.md; mas mahaba, hal. LHIO 15 digits → unang 13).
- **Header row detection:** hanapin ang row na may kilalang header (hal. `SERIES` / `CLAIM_SERIES`), hindi naka-fix na row number —
  sa Excel workbook ng FINMAREP, may instruction/placeholder rows sa itaas; sa raw na export, malamang row 1 ang header.
- **"-" = blangko.** Sa Excel, pinapalitan ng "-" ang mga blank cell; sa pag-import, ang "-" (at "" o puro espasyo) ay NULL.

**Raw Matching sheet sa Excel ng FINMAREP ("1. RAW-DATA MATCHING"):** row 1 = instructions ("Right click on cell B4,
select Keep Text Only" — ibig sabihin, ipine-paste bilang text para hindi masira ang SERIES; "Duplicates will be highlighted
orange"), row 2 = "-" placeholders ("Change blanks to '-'"), **row 3 = headers**, data mula row 4.
Columns: CLAIM IS PART OF ICS? *(formula — kinukuwenta, hindi input)* · PH_INST_CODE · SERIES · MECNO · PATLNAME · PATFNAME ·
PATMNAME · WORLNAME · WORFNAME · WORMNAME · DATE_ADM · DATE_DIS · DATE_REC · DATE_RECON · LAST_REFILED · STATUS ·
TOTAL_ACR_AMOUNT · LATEST_CHECK_DT · TOTAL_TOT_AMNT · LATEST_CTRL_NO · LATEST_CTRL_DT.
Duplicate SERIES sa Raw Matching ay dapat i-flag (hindi basta i-drop).

**Status Trail sheet sa Excel ng FINMAREP ("2. Status as of matching date"):** instructions sa itaas: "…before pasting here
and make sure any status beyond <cutoff date> is excluded" at "sort TIME_REC first (descending) then sort descending DATE_TAGGED"
(ibig sabihin: pinakabago ayon sa DATE_TAGGED, tapos TIME_REC — tugma sa §3a). Columns: SERIES · TIME_REC · DATE_TAGGED · PROCESS.
Sa kanan ng parehong sheet: lookup table **"Status interpretation based on trail"**: SYSTEM TAG · INTERPRETATION (= §3b mapping).
Sa system: hindi na kailangang i-sort o i-filter nang mano-mano; ang cutoff (Report Date / Matching Date) ay inilalapat sa SQL.

**Pangalawang Status Trail sheet ("3. Status as of"):** parehong columns at parehong lookup table; instruction: "…make sure any
status beyond <Report Date, hal. December 31, 2025> is excluded" at **"Convert TIME_REC to number"** (naka-text ang TIME_REC sa
export; sa system, i-parse bilang integer — kailangan ito sa `DATE_TAGGED + TIME_REC/100000` ng §3a; hindi-numerong TIME_REC
→ i-flag). Ang dalawang sheet (2 at 3) ay **iisang Status Trail data na may magkaibang cutoff** → sa system, isang upload lang,
dalawang cutoff sa SQL.

**Pangatlong Status Trail sheet ("Status as of", cutoff = nakaraang Report Date, hal. June 30, 2025):** parehong columns
(SERIES · TIME_REC · DATE_TAGGED · PROCESS) at lookup table, dagdag ang gitnang table na **"Auto list of unique claim series
and latest process tagging"** (SERIES · latest PROCESS · STATUS INTERPRETATION — formula; sa system, kinukuwenta sa SQL).
Kaya **tatlong cutoff** ang Status Trail, katapat ng 3 column group ng Annex A at Matching Report:
**Report Date · nakaraang Report Date · Matching Date** — lahat mula sa iisang upload (tingnan ang #13 at #17).

**Payment Details sheet sa Excel ng FINMAREP ("4. Payment Details"):** Columns: ICS? *(formula — kinukuwenta)* · SERIES ·
DATE_EXT · CHECK_NO · CHECK_DT · ISIRM · IS_DCPM · PR_NO · TRANCHE_NUMBER · CW_TAX · RECEIPT_NO · RECEIPT_DT · CPAY_TO ·
(huling column — tingnan ang Open Question #18). May TRANCHE_NUMBER → maaaring higit sa isang row bawat SERIES.

**RTH/Denial Reasons sheet ("5. Reasons for RTH and Denial") — Yugto 2:** Columns: CLAIM SERIES NUMBER · (blangkong column,
tingnan ang #19) · DEF CODE · REASON · EFFECT · ICD CODE · HEALTH PROFESSIONAL. **Maraming row bawat claim** (isa bawat
deficiency code). Ang EFFECT ay code (hal. "P"). Sa kanan ng sheet: hiwalay na table na **CLAIM SERIES NUMBER · EFFECT**
(isang EFFECT bawat claim — malamang ito ang pinagkukunan ng "History Effect" sa Matching Report).
Posibleng pinagkukunan din ito ng ICD code at Health Care Professional sa Matching Report (tingnan ang #15).

**Motion for Reconsideration sheet ("6. Motion for Reconsideration") — Yugto 2:** header sa row 3 (rows 1–2 blangko).
Columns (tugma sa §2): SERIES · hciPAN · memberPIN · mrRcvDate · approval · finalRecom · finalBasis · dateFinalized ·
uploadedDate · crcReceivedDate · iniDateEncoded · finalDateEncoded. Mapping sa Matching Report: tingnan ang #20.

**PARD sheet ("7. PARD") — Yugto 2:** Columns (tugma sa §2): SERIES · ENTRY_DATE · APPROVAL_SOURCE.
Malamang na mapping sa Matching Report (Appeals): PARD Receive Date = ENTRY_DATE, Latest PARD Status = APPROVAL_SOURCE
(pinakabagong ENTRY_DATE bawat SERIES) — kumpirmahin (#21).

**PF Name sheet ("8. PF Name") — Yugto 2:** Columns (tugma sa §2): SERIES · DOCTORS NAME. Malamang na pinagkukunan ng
"Health Care Professional" sa Matching Report; kapag maraming doktor ang isang SERIES, pagsasamahin (#22).

**Tagging of Issue sheet ("9. Tagging of Issue") — Yugto 2:** Columns (tugma sa §2): SERIES · DATE_TAGGED · PROCESS.
Malamang na mapping sa Matching Report (Internal Data Only): Process/Policy Issue Tagging (tagging date) = DATE_TAGGED,
Latest Tag Status = PROCESS (pinakabagong DATE_TAGGED bawat SERIES) — kumpirmahin kasama ng Untagging (#23).

**Untagging of Issue sheet ("10. Untagging of Issue") — Yugto 2:** Columns (tugma sa §2): SERIES · DATE_UNTAGGED · PROCESS.
Malamang na mapping: Process/Issue Resolution (untagging date) = DATE_UNTAGGED, Latest Untag Status = PROCESS (pinakabago
bawat SERIES). Ang "Issue" at "Last Date Tag" sa Matching Report ay malamang kinukuwenta mula sa Tagging + Untagging (#23).

**ICD Codes sheet ("11. ICD Codes") — Yugto 2:** Columns (tugma sa §2): SERIES · ICDCODE · RVSCODE · TOTAL_ACR_AMOUNT.
Malamang na pinagkukunan ng "First Case Rate" at "Second Case Rate (ICD10/RVS)" sa Matching Report (#24). Bukas pa rin ang #3
(sa data, mukhang nagkakapalit ang laman ng ICDCODE at amount) — sa import, i-validate ang bawat column (code vs. numero) at i-flag.
- **Isang facility bawat extraction** — ang Raw Matching / Status Trail / Payment Details / HO ICS ay ina-upload ng FINMAREP para sa isang recon run ng isang facility.
- **HF ICS: facility muna nagsa-submit** kahit kailan; kapag gumawa ang FINMAREP ng recon run, pipiliin ang pinakabagong submission ng facility na iyon.
- FINMAREP: pwedeng mag-upload at mag-match sa kahit anong branch.
- **Recon run** (ginagawa ng FINMAREP): facility, Report Date, **nakaraang Report Date** (ilalagay ng FINMAREP; ang status
  "as of" nito ay kinukuwenta mula sa parehong Status Trail upload — sagot sa #13/#25), Matching Date,
  **LOI coverage start/end — itinatakda bawat run** (sagot sa #10a), at ang HF ICS submission na gagamitin
  (default: pinakabagong complete ng facility).
- Bawat run ay may mga upload ayon sa uri (HO ICS, Raw Matching, Status Trail, Payment Details, at Yugto 2); pwedeng
  higit sa isang upload bawat uri (hal. Status Trail na hinati) — ang lahat ng 'complete' ay pinagsasama.
- Ang extraction data (raw tables) ay makikita lang ng PhilHealth roles (FINMAREP, BAS Processor, Branch Admin) ayon sa
  saklaw nila; ang access ng facility sa resulta ay pagpapasyahan sa Yugto C (#16).

---

## 3. Status determination

### 3a. Latest trail process
Para sa bawat Claim Series: kunin ang trail row na may pinakamataas na `DATE_TAGGED + TIME_REC/100000`
(pinakabagong petsa, tapos pinakamataas na TIME_REC).
- **As of Report Date:** trail rows na `DATE_TAGGED <= report_date` lang.
- **As of Matching Date:** trail rows na `DATE_TAGGED <= matching_date`.

### 3b. Process → Interpretation (editable mapping table sa Settings)
- **FOR PAYMENT – FA to assess timing of payment:** ADJU: FOR PAYMENT APPROVAL, CHECK PREPARATION, PAYMENT APPROVAL,
  PAYMENT NOTICE, VOUCHER GENERATION, VOUCHER TRANSMITTAL
- **RTH/DENIED – FA to assess timing of RTH/Denial:** RTH/DENIAL CTRL NO. GENERATION, RTH/DENIAL POSTING
- **DENIED:** CRC DENIED
- **IN PROCESS:** lahat ng iba pa (hal. VALIDATION, ADJUDICATION, EDITING, MPR *, PENDING DUE TO SYSTEM/POLICY ISSUES,
  REFERRED TO / RETURNED BY *, CRC GRANTED, CRC RECEIVED, TAGGING AS REFILED CLAIM, VOUCHER EXCLUSION/UNTRANSMITTAL,
  PAYMENT UN-APPROVAL, RTH/DENIAL CTRL NO. EXCLUSION/INCLUSION, eCLAIMS TO nCLAIMS UPLOADING, atbp.)
- Hindi kilalang process → "UNMAPPED", ipakita sa admin para i-map.

### 3c. Final status (PAID, APPROVED FOR PAYMENT, RTH, DENIED, IN PROCESS, UNMATCHED)
- Raw STATUS code: **G** = good/approved, **D** = denied, **P** = RTH.
- Wala sa Raw Matching → **UNMATCHED** (o "Deleted Claim" sa HO ICS side).
- **Decision table "as of" petsa X (kinumpirma ng user, 2026-10-05)** — unang tumugma, sa ganitong ayos:
  1. Wala sa Raw Matching → **UNMATCHED**
  2. May bayad sa Payment Details na `coalesce(CHECK_DT, DATE_EXT) <= X` → **PAID**
  3. Huling trail (DATE_TAGGED <= X) = FOR PAYMENT → **APPROVED FOR PAYMENT**
  4. Huling trail = DENIED → **DENIED**
  5. Huling trail = RTH/DENIED → STATUS P → **RTH**; STATUS D → **DENIED**
  6. Huling trail = IN PROCESS → **IN PROCESS**
  7. Walang trail hanggang X → STATUS G → **APPROVED FOR PAYMENT**; D → **DENIED**; P → **RTH**
  8. PROCESS na wala sa mapping → **UNMAPPED** (ipakita para i-map)
- Ang X ay bawat isa sa 3 cutoff: Report Date, nakaraang Report Date, Matching Date.
- **NOT YET FILED (desisyon ng user, 2026-10-05):** kapag ang DATE_REC (filing date) ng claim ay **pagkatapos ng X**, ang status
  as of X ay **NOT YET FILED** (sinusuri kaagad pagkatapos ng UNMATCHED, bago ang PAID). Hindi ito kasama sa status totals ng
  cutoff na iyon sa Annex A (ipinapakita nang hiwalay ang bilang), at walang "amount used for recon" sa cutoff na iyon.
  Ang rule 7 (walang trail → G/D/P) ay para lang sa mga claim na naka-file na. Pansamantala (#27): sa reconciliation as of
  Report Date, ang NOT YET FILED ay itinuturing na gaya ng IN PROCESS (recon amount at reconciling item).
- **Pansamantala (tingnan ang #26):** trail na RTH/DENIED pero STATUS ay hindi P/D, o walang trail at STATUS ay hindi G/D/P
  → **IN PROCESS**. Payment row na walang CHECK_DT, DATE_EXT at RECEIPT_DT → itinuturing na bayad sa lahat ng cutoff.
  Bayad na "may OR date o mode of payment" lang ang binibilang (§3d).

### 3c-bis. "Latest lang" bawat Claim Series (desisyon ng user, 2026-10-05; kinumpirma pati ang tie-break at na ang "Total Amount Paid" ay halaga ng pinakabagong tranche lang)
Kapag higit sa isang row ang isang Claim Series sa anumang upload, **ang pinakabagong row lang ang gagamitin** — para sa halaga,
check date, status, at control no. — anuman ang status (PAID, RTH, DENIED, atbp.). Hindi sinusuma.
- **Status:** pinakabagong trail (§3a: DATE_TAGGED, tapos TIME_REC).
- **Payment Details:** row na may pinakabagong **CHECK_DT** → ang TOTAL_TOT_AMNT, CHECK_NO, OR no./date, mode of payment nito.
  Tie-break (parehong CHECK_DT): pinakabagong DATE_EXT, tapos RECEIPT_DT, tapos pinakamataas na TRANCHE_NUMBER, tapos huling row sa file.
- **Raw Matching (duplicate SERIES):** row na may pinakabagong **LATEST_CHECK_DT**; tie-break: LATEST_CTRL_DT, DATE_RECON,
  LAST_REFILED, DATE_REC, tapos huling row sa file. Ang duplicate ay ifa-flag pa rin sa report.
- **RTH / Denied:** LATEST_CTRL_NO at LATEST_CTRL_DT ng napiling Raw Matching row.

### 3c-ter. Mga sagot para sa Yugto C (2026-10-05)
- **#8 — Total Amount Paid (PAID):** mula sa **Payment Details** (TOTAL_TOT_AMNT ng pinakabagong row ayon sa §3c-bis),
  hindi sa TOTAL_TOT_AMNT ng Raw Matching.
- **#2 — Recon Amount kapag APPROVED FOR PAYMENT:** **all case rate** (TOTAL_ACR_AMOUNT), hindi 0.
- **#10b — Within Recon Period:** ayon sa **eksaktong petsa** ng RECREF: `coverage_start <= RECREF <= coverage_end`.
- **#16 — Facility access sa resulta:** makikita ng facility ang **Matching Report at Annex A ng sarili nila**, pero
  **nakatago ang "Internal Data Only"** columns. **Ang HO ICS Recon (bawat row) ay PhilHealth lang.**
- **#5 — Duplicate sa HF ICS:** ang pangalawa+ na paglitaw ay may status na **DUPLICATE** (sa lahat ng cutoff), reconciling item
  na **"Deduct from HF: Unmatched Claims – Duplicate"**, recon amount = ICS amount; hindi ito binibilang sa ibang status.
- **Kailangang input bago mag-matching:** may complete na upload ang **lahat ng apat** (HO ICS, Raw Matching, Status Trail,
  Payment Details) at may HF ICS submission ang run.
- **Invalid Claim Series sa HF ICS** (kulang ang digits, blangko, TOTAL row): itinuturing na **UNMATCHED** sa Annex A, kasama ang
  halaga (desisyon ng user, 2026-10-05).
- **Unreconciled Balance:** HF = kabuuan ng ICS amount ng **lahat** ng HF ICS rows (kasama ang invalid, dahil UNMATCHED sila);
  PhilHealth = kabuuan ng ESTIMATED_AMT ng HO ICS.
- **Dalawang bersyon ng Annex A (desisyon ng user, 2026-10-05):** *Internal* (PhilHealth lang) — kumpleto; *Facility* — walang
  impormasyon tungkol sa mga claim na nasa HO ICS pero **wala sa HF ICS** ng facility (hal. "In Process – Not on HF ICS" /
  "Add to HF: Processed claims not reported by HF"). Ang mga claim na iyon ay makikita lang sa internal annex.
  Sa facility version: **walang PhilHealth-only na linya** — ang HO rows na wala sa HF ICS ay hindi kasama sa bilang at halaga,
  at tinatanggal ang linyang "In Process – Not on HF ICS". (Mula 2026-10-06: **balanse na rin ang facility version** —
  tingnan ang "Balanse ang COUNT at AMOUNT" sa ibaba.)
- **Reconciliation of balances (kinumpirma ng user, 2026-10-05; sagot sa #5)** — as of Report Date:

  | Linya | HEALTH FACILITY | PHILHEALTH |
  |---|---|---|
  | Unreconciled Balance | Σ ICS amount (lahat ng HF ICS rows) | Σ ESTIMATED_AMT (HO ICS) |
  | Paid / Denied / RTH Claims (hiwalay na linya) | − ICS amount ng PAID / DENIED / RTH | − estimated amt ng HO "Already Paid/RTH/Denied" ayon sa status |
  | Unmatched Claims – Duplicate | − ICS amount ng DUPLICATE | |
  | Unmatched | − ICS amount ng UNMATCHED | |
  | In Process – Not on HF ICS *(internal lang)* | + estimated amt ng HO "Add to HF: Processed claims not reported by HF" | |
  | In Process – Not on HO ICS | | + recon amount ng HF "Add to PHIC Balance: In Process" |
  | Payment in Transit (ABP – Processed) | | + recon amount ng HF "Add to PHIC Balance: Payment in Transit" |
  | For Archiving – Recon Exception | | − estimated amt ng HO "Recon Exception" |
  | For Archiving – Unmatched (Deleted) – Not on NClaims | | − estimated amt ng HO "Deleted Claim" |
  | Net Upgrade (Downgrade) – HF ICS | + Σ (recon amount − ICS amount) ng APPROVED / IN PROCESS | |
  | Reconciled Balance | kabuuan | kabuuan (diperensya = 0 sa internal) |
- **Balanse ang COUNT at AMOUNT ng parehong version (desisyon ng user, 2026-10-06; pumapalit sa mga nauna sa itaas kung salungat):**
  - *Facility version:* ang sariling HF ICS lang ng facility + ang HO ICS rows ng **parehong** mga claim. Balanse rin ito.
  - *Internal:* HF ICS + buong HO ICS + matching ni FINMAREP.
  - Bawat linya ay may bilang ng claim at halaga; may **Difference** (claims at amount) na dapat 0, may babala kapag hindi.
  - **Breakdown = Matching Report** (column na "Annex A line – Health Facility" at "– PhilHealth") at, sa internal, ang
    **HO ICS Recon**. Ang kabuuan ng mga row na may parehong line = halaga at bilang ng linya sa Annex.
  - Mga dagdag na linya: **For Archiving – Recon Exception sa HF column** (claim na nasa HF at HO ICS pero labas sa LOI
    coverage — ibinabawas ang ICS amount; hindi kasama sa Net Upgrade); **Net Upgrade (Downgrade) – PHIC books** sa PhilHealth
    column (= Recon Amount − Amount on PHIC books ng mga claim na nasa reconciled balance ng parehong side, hal. A4P = ACR);
    **Duplicate on HO ICS** at **Invalid Claim Series – HO ICS** sa PhilHealth column (lumalabas lang kapag may laman).
  - Ang "canonical" HO row ng isang series (kapag duplicate sa HO ICS) ay ang may pinakabagong RECREF (tapos huling row) —
    pareho ng pinagkukunan ng Amount on PHIC books; ang iba ay "Duplicate on HO ICS".
- **Basehan ng status (kinumpirma ng user, 2026-10-06):** pinakabagong status sa raw files ni FINMAREP (complete uploads ng run),
  **hanggang sa cutoff**. Ang Reconciliation of balances ay **as of Report Date** — pareho sa internal at facility version.
  Ang pinakabagong status sa buong file ay ang "as of Matching Date" (impormasyon lang; nakikita rin ng facility).
- **#12 — "Received claims for the period <start> to <end>":** kinukuha sa data — pinakamaagang DATE_REC (filing date) ng mga
  na-match na HF ICS claim hanggang sa Report Date.
- **Ang matching ay background job** (pg_cron): ang "Run matching" ay naglalagay ng job sa pila; makikita ang status
  (queued → running → done / failed). Ang data na naka-upload sa oras na tumakbo ang job ang ginagamit.

### 3c-quater. Yugto 2 sa Matching Report (mga sagot ng user, 2026-10-06)
- **Ang Matching Report ay "latest lang"** para sa lahat ng Yugto 2 data (gaya ng §3c-bis).
- **Hiwalay na "Claim History"** (bagong requirement): makikita ang buong kasaysayan ng isang claim series — lahat ng
  status trail, bayad, RTH/Denial reasons, MR, PARD, tagging/untagging — hindi lang ang latest.
- **#19 RTH/Denial Reasons:** History Effect = EFFECT ng **pinakabagong** reason ng claim (huling row sa pinakabagong upload).
- **#20 MR:** MR Received Date = mrRcvDate, **MR Status = finalRecom**, Decision Release Date = dateFinalized; pinakabagong MR ayon sa mrRcvDate.
- **#21 PARD (pansamantala, ayon sa "latest"):** PARD Receive Date = pinakabagong ENTRY_DATE; Latest PARD Status = APPROVAL_SOURCE nito.
- **#22 PF Name:** Health Care Professional = **lahat ng doktor, pinagsama** ("; "), walang ulit.
- **#23 Tagging/Untagging (pansamantala, ayon sa "latest"):** tagging date/status = pinakabagong DATE_TAGGED/PROCESS;
  untagging date/status = pinakabagong DATE_UNTAGGED/PROCESS; Last Date Tag = tagging date.
- **#24 ICD Codes:** First Case Rate = row na may **mas mataas na TOTAL_ACR_AMOUNT**, Second = kasunod; ipinapakita bilang "ICD / RVS".
- **#23b Issue (2026-10-06):** **OPEN** kapag ang pinakabagong DATE_TAGGED ay mas bago kaysa sa pinakabagong DATE_UNTAGGED (o walang untag);
  **RESOLVED** kapag may untag na kasabay o mas bago; blangko kapag walang tag.
- **#15 Payment TAT (2026-10-06):** (petsa ng bayad − simula) − araw na may issue, sa araw.
  Simula = LATEST REFILING DATE kung na-refile, kung hindi ay FILING DATE (DATE_REC). Petsa ng bayad = CHECK_DT ng pinakabagong
  payment, kung wala ay DATE_EXT (bank advise); PAID as of matching date lang (kung hindi, blangko).
  Araw na may issue = mga araw na naka-tag (bawat tag → unang untag na kasabay o mas bago; kung wala → petsa ng bayad), pinagsama ang
  nagsasapaw, sa loob lang ng [simula, petsa ng bayad). Ipinapakita rin bilang "Days on Issue". Internal Data Only.
- **#15 iba pa (2026-10-06):**
  - **Type of Claim** (Internal Data Only) = **eClaims / Manual**, mula sa bagong raw data na ina-upload ng FINMAREP
    (upload "Type of Claim": SERIES + CLAIM TYPE; pinakabagong row bawat series; ipinapakita kung ano ang nasa file).
  - **Patient Reference No.** = optional na column sa HF ICS ng facility (pinipili sa column mapping ng Upload Claims).
  - **Filed Amount vs. Actual Payment Upgrade** = Recon Amount − ICS amount (filed amount ng HF), para sa **PAID,
    APPROVED FOR PAYMENT at IN PROCESS** lang (as of Report Date; ang UNMAPPED at NOT YET FILED ay gaya ng IN PROCESS ayon sa
    #26/#27); blangko sa iba. Recon Amount: PAID = Total Amount Paid; A4P = All Case Rate (#2, kinumpirma ulit);
    IN PROCESS = HO amount → ACR → ICS amount.
- **#14 (2026-10-06):** kinumpirma — ang 3 column ay Status / Last Trail Date / Last Trail Process as of Matching Date.
- **#18a (2026-10-06):** kinumpirma — ang huling column ng Payment Details ay TOTAL_TOT_AMNT.
- **#3 (2026-10-06):** may tunay na ICD code na numero lang, kaya hindi ito awtomatikong pinagpapalit. Fina-flag sa upload
  (ICD code na hindi nagsisimula sa letra; amount na hindi numero), ipinapakita ang mga row para ma-double check ni FINMAREP,
  at itinatala sa extra ng row.
- **#26 (2026-10-06):** kinumpirma — RTH/DENIED na trail pero STATUS G/blangko, o walang trail at STATUS blangko/iba → **IN PROCESS**;
  UNMAPPED ay gaya ng IN PROCESS sa Recon Amount.
- **#27 (2026-10-06):** kinumpirma — NOT YET FILED as of Report Date ay **gaya ng IN PROCESS** sa recon amount at reconciling item.

### 3d. Payment
- **Mode of payment:** may DATE_EXT (bank advise) → `AC`; may CHECK_NO → `CHECK`; ISIRM = T → `IRM`;
  IS_DCPM = T → `DCPM LIQ`; may PR_NO → `PR`.
- **Payment status:** may OR date o mode of payment → `PAID`; kung wala at STATUS = G → `APPROVED FOR PAYMENT`.
- **Total amount paid:** TOTAL_TOT_AMNT mula sa Payment Details (0 kung wala).
- **RTH / Denied control no.:** LATEST_CTRL_NO kapag P / D; issuance date = LATEST_CTRL_DT.

---

## 4. Outputs

### 4a. Matching Report (isang row bawat claim)
Item no., patient reference no., first/second case rate (ICD/RVS), health care professional, Claim Series, member PIN,
pangalan ng pasyente at member (last/first/middle), admission/discharge/filing date, latest reconsidered date,
latest refiling date, filing TAT (filing − discharge), refiling TAT, status as of report date + last trail date/process,
status as of matching date + last trail date/process, raw status code, all case rate, PHIC payment processed date,
bank advise date, check no., IRM?, DCPM?, PR no., OR no., OR date, mode of payment, payment status, total amount paid,
ICS amount (HF books), amount on PHIC books, amount used for recon, upgrade (downgrade), RTH/denied control no.,
control no. issuance date, date RTH, date denied.

**Amount used for recon:** PAID → total amount paid; kung hindi → amount sa PHIC books; kung wala → all case rate.

**Columns ng kasalukuyang Excel Matching Report** (header rows: Name of Health Facility, Report Date, Matching Date;
ang Report Date sa Excel ay date serial, hal. 46022 = 12/31/2025). Mga grupo at columns, sa ganitong ayos:
- **Health Facility Data:** Item No. · Patient Reference No. · First Case Rate (ICD10/RVS) · Second Case Rate (ICD10/RVS) ·
  Health Care Professional
- **Claim Details:** Claim Series Number · Member's PIN (label na "Member's ID" sa lumang template; pinalitan ayon sa user, 2026-10-06; mula sa MECNO) · Patient's Last/First/Middle Name · Member's Last/First/Middle Name ·
  Admission Date · Discharge Date · Filing Date · Latest Reconsidered Date · Latest Refiling Date ·
  Claims Filing TAT (discharge to filing) · Claims Refiling TAT
- **Status Details:** Status as of <Report Date> · Last Trail Date as of <Report Date> · Last Trail Process as of <Report Date> ·
  Status as of Matching Date · Last Trail Date as of Matching Date · (2 pang column na "Status as of Matching Date" — tingnan ang
  Open Question #14) · All Case Rate
- **Payment Details:** PHIC Payment Processed Date · Bank Advise Date · Check No. · IRM Population? · DCPM Population? ·
  Payment Recovery No. · OR No. · OR Date · Mode of Payment · Payment Status · Total Amount Paid ·
  ICS Amt (amount on HF books) · Amount on PHIC Books · Amount Used for Recon (as of <Report Date>) ·
  Amount Used for Recon (as of <nakaraang Report Date>) · Amount Used for Recon (as of Matching Date) ·
  Filed Amount vs. Actual Payment Upgrade
- **RTH / Denied:** RTH Control Number · Denied Control Number · Control Number Issuance Date ·
  RTH/Denied (for validation of status; kung TRUE, dapat RTH/DENIED ang status) · Date RTH · Date Denied · History Effect
- **Motion for Reconsideration:** MR Received Date · MR Status · Decision Release Date
- **Appeals:** PARD Receive Date · Latest PARD Status
- **Internal Data Only** (hindi para sa facility): Type of Claim · Process/Policy Issue Tagging (tagging date) ·
  Latest Tag Status · Process/Issue Resolution (untagging date) · Latest Untag Status · Issue · Last Date Tag · Payment TAT

### 4b. HF ICS Reconciliation (bawat claim sa libro ng facility)
- `in_ho_ics`: nasa HO ICS ba?
- `duplicate`: pangalawa o higit pang paglitaw ng parehong Claim Series sa HF ICS.
- **Recon amount:** duplicate → ICS amount; PAID → amount paid (Payment Details); APPROVED FOR PAYMENT → all case rate
  (sagot sa #2); RTH/DENIED/UNMATCHED → ICS amount;
  IN PROCESS → HO amount kung meron, kung wala → all case rate, kung wala → ICS amount.
- **Upgrade (downgrade)** = recon amount − ICS amount.
- **Columns ng kasalukuyang Excel template** (sheet "CLAIMS REPORTED AS ICS CLAIMS ON HF BOOKS AS OF <REPORT DATE>"),
  sa ganitong ayos: Also on ICS of HO? · CSN from ICS · ICS Amount (must equal HF ICS) · Amount per HO (from HO) ·
  TOT_AMT (from Universe) · ACR Amount · Status per Universe Matching (G,D,P) · Duplicate Check ·
  Status per Matching (as of <date>) · Recon Amount · Difference (Upgrade / Downgrade) · Reconciling Item (Add to PHIC Balance).
  Input mula sa facility: CSN at ICS Amount lang; ang iba ay kinukuwenta.
- **Reconciling item** (kapag wala sa HO ICS lang):
  UNMATCHED → "Deduct from HF: Unmatched"; APPROVED FOR PAYMENT → "Add to PHIC Balance: Payment in Transit";
  IN PROCESS → "Add to PHIC Balance: In Process"; iba pa → "Non-Reconciling Item".

### 4c. HO ICS Reconciliation (bawat claim sa libro ng PhilHealth)
- `in_hf_ics`: nasa HF ICS ba?
- **Coverage period** (setting bawat run, hal. 2023–2026): RECREF year nasa loob → "Within Recon Period", kung hindi → "Recon Exception".
  Sa Excel, ito ay **"Reconciliation coverage per LOI"** — start at end date mula sa LOI ng facility (hal. 1/1/2024 – 12/31/2026).
- **Columns ng kasalukuyang Excel template** (sheet "CLAIMS REPORTED AS IN PROCESS IN PHIC BOOKS AS OF <REPORT DATE>",
  headers sa ilalim ng coverage rows), sa ganitong ayos: ICS of HF? · CLAIM_SERIES · ESTIMATED_AMT ·
  Status based on Claims Universe (D,G,P,- ; #N/A = wala sa Universe = Deleted) · RECREF Year (from HO ICS) ·
  Claim is within Recon Period? · Status as of <date> (from Matching: PAID, DENIED, RTH, IN PROCESS, APPROVED FOR PAYMENT) ·
  Helper · Reconciling Items. Input mula sa HO ICS: CLAIM_SERIES, ESTIMATED_AMT, RECREF; ang iba ay kinukuwenta.
- **Reconciling item:**
  1. Wala sa Raw Matching → "Deduct from PHIC: Deleted Claim"
  2. Recon Exception → "Deduct from PHIC: For Archiving – Recon Exception"
  3. PAID/RTH/DENIED → "Deduct from PHIC: Already Paid/RTH/Denied"
  4. Wala sa HF ICS at APPROVED/IN PROCESS → "Add to HF: Processed claims not reported by HF"
  5. Nasa HF ICS → "Non-Reconciling Item"

### 4d. Annex A (para sa mga accountant)
- **Summary per status** (PAID, APPROVED FOR PAYMENT, DENIED, RTH, IN PROCESS, UNMATCHED, DUPLICATE, FOR ARCHIVING):
  bilang ng claims, halaga, at porsyento, para sa Report Date at Matching Date, HF side at PhilHealth side.
- **Reconciliation of balances**, HF vs PhilHealth:
  Unreconciled Balance (HF = kabuuang ICS amount; PhilHealth = kabuuang HO ICS amount)
  → Add (Less): Paid, Denied, RTH, Unmatched – Duplicate, Unmatched, In Process – Not on HF ICS,
  In Process – Not on HO ICS, Payment in Transit, For Archiving – Recon Exception,
  For Archiving – Unmatched (Deleted), Net Upgrade (Downgrade)
  → **Reconciled Balance**; ang diperensya ng HF at PhilHealth ay dapat **0**.
- Header: hospital name, accreditation number, branch, report date, matching date; Prepared by / Reviewed by.
- Export sa Excel na kahawig ng kasalukuyang Annex A.

**Layout ng kasalukuyang Excel Annex A** (istruktura lang; walang tunay na pangalan o halaga dito):
- Pamagat: "ANNEX A: PhilHealth eClaims Reconciliation Report*", "as of <REPORT DATE>".
- **Kaliwa — Reconciliation of balances** (header: Hospital Name, Accreditation Number, Branch; columns: Particulars · Health Facility · PhilHealth):
  Unreconciled Balance → Add (Less) Reconciling Items: Paid Claims; Denied Claims; RTH Claims; Unmatched Claims – Duplicate;
  Unmatched; In Process – Not on HF ICS; In Process – Not on HO ICS; Payment in Transit (ABP – Processed);
  For Archiving – Recon Exception; For Archiving – Unmatched (Deleted) – Not on NClaims; Net Upgrade (Downgrade) – HF ICS
  → Reconciled Balance.
- **Gitna — Summary of Status of Received eClaims** (HF side). Coverage: "Received claims for the period <start> to <end>,
  based on submitted Summary Report – Unpaid Claims – Accounts Receivable". Rows: PAID, APPROVED FOR PAYMENT, DENIED, RTH,
  IN PROCESS, UNMATCHED, DUPLICATE, UPGRADE (DOWNGRADE), TOTAL.
- **Kanan — Summary of Status of ICS Claims** (PhilHealth/HO side). Coverage: "Recorded ICS claims from HO as of <report date>".
  Rows: PAID, APPROVED FOR PAYMENT, DENIED, RTH, IN PROCESS, FOR ARCHIVING, UPGRADE (DOWNGRADE), TOTAL.
- Bawat summary ay may **3 column group**, bawat isa ay No. of Claims · Amount · Percentage:
  **as of <Report Date>** · **as of <nakaraang Report Date>** (hal. June 30 bago ang Dec 31; mula sa nakaraang run) ·
  **as of <Matching Date>**.
- Footnotes: "*Partial report only… based only on submitted ICS report matched on <matching date>. Reflected status is as of
  <report date>…"; paliwanag na kumpleto lang ang recon kapag kumpleto ang AR data o may LOI na nagsasaad ng cut-off;
  in-process claims ay subject sa adjudication; denied/RTH ay ibinabawas sa Receivable (RTH ay irerekord ulit kapag na-refile;
  appealed/MR claims ay ihihiwalay).
- References: PC 2019-001 (recording ng RTH at denied claims), PC 2023-0028 (periodic reconciliation).
- Pivot sa ilalim: Count at Sum of "Amount Used for Recon (as of <report date>)" bawat status (galing sa Matching Report);
  kasama ang DUPLICATE at UNMATCHED; may Grand Total.
- Signatories (pangalan + posisyon, editable bawat run): Prepared by (hal. Financial Analyst I), Reviewed by (hal. Accountant III),
  Certified Correct (hal. Head, Fund Management Section), Acknowledged by.

---

## 5. Suggested tables (Supabase)
`facilities`, `profiles`, `recon_runs` (facility, report_date, matching_date, coverage_start, coverage_end, status),
`upload_batches`, `column_mapping_profiles`, `hf_ics_records`, `ho_ics_records`, `raw_claims`, `status_trail`,
`payment_details`, `process_status_map`, `recon_results` (matching report row + computed fields),
Yugto 2 (0016): `rth_reasons`, `mr_records`, `pard_records`, `pf_names`, `issue_tags`, `issue_untags`, `icd_codes`.
Lahat may `run_id`, lahat naka-RLS, may index sa normalized Claim Series.

---

## 6. Open questions (sagutin bago i-finalize)
1. Ang sheet "3STATUS AS OF DECEMBER 31, 2025" ay ginagamit para sa status "AS OF JUNE 30, 2026". Isang cutoff date lang ba
   (Report Date) ang dapat, at saan galing ang "June 30, 2025" na column sa Annex A (nakaraang run)?
2. Sa ICS recon, ang PAID/APPROVED ay gumagamit ng "amount paid", na 0 kapag APPROVED pa lang. Tama ba, o all case rate dapat?
3. Sa ICD Codes sheet, mukhang nagkapalit ang headers (ICDCODE ay may amount). Ano ang tamang ayos?
4. Saan gagamitin ang Tagging/Untagging of Issue, PARD, at MR sa output?
5. Ang "Unmatched Claims – Duplicate" at ilang linya sa Annex A ay naka-hardcode na numero sa Excel. Paano ito kinukuwenta?
6. May mga #REF! error sa PIVOT sheet; Annex A ang susundin, hindi ang PIVOT?
7. Sino ang mga user: PhilHealth staff lang, o pati facility at accountants? Sino ang mag-a-upload at sino ang titingin?
   **Bahagyang sagot (2026-10-05):** Facility users = lahat ng accredited facilities (sariling facility lang). PhilHealth users =
   **FINMAREP** (siya lang ang nag-a-upload ng PhilHealth extractions para sa matching) at **BAS Processor** (view-only: reports at
   analytics, pwedeng mag-export). HF ICS → facility ang nag-a-upload. HO ICS → FINMAREP. FINMAREP ang gumagawa ng run at
   nagti-trigger ng matching. FINMAREP: nakikita ang lahat ng branch; UI filter na naka-default sa mga branch na hawak niya.
   BAS Processor: RLS-restricted sa mga naka-assign na branch lang.
   FINMAREP: pwedeng mag-upload at mag-match sa kahit anong branch (2026-10-05).
   Bukas pa: pwede bang mag-export ang facility.
8. Sa HF ICS recon template, "TOT_AMT (from Universe)" ay galing sa Raw Matching (`TOTAL_TOT_AMNT`), pero sinasabi ng §3d
   na ang "total amount paid" ay mula sa Payment Details. Alin ang ginagamit sa Recon Amount kapag PAID?
9. Ang "Status per Matching (as of <date>)" sa template: Report Date ba o Matching Date ang <date>? (kaugnay ng #1)
10. Coverage per LOI: (a) naka-save ba ito sa facility (LOI start/end) o itinatakda bawat run? (b) Ang "within recon period" ba
    ay ayon sa **taon** ng RECREF o sa **eksaktong petsa** ng RECREF laban sa start/end date? (c) Ano ang gagawin sa facility
    na walang LOI?
11. Ano ang laman/gamit ng column na "HELPER" sa HO ICS recon sheet?
12. Annex A "Received claims for the period <start> to <end>" (HF side): ito ba ay hiwalay sa LOI coverage? Saan galing ang
    start/end (hal. unang petsa ng eClaims at Report Date ng AR summary ng facility)?
13. Annex A "as of <nakaraang Report Date>": kukunin ba ito sa nakaraang recon run ng parehong facility sa system? Paano kung
    wala pang nakaraang run (unang beses)? (kaugnay ng #1)
14. Matching Report: may 3 column na "Status as of Matching Date". Ang pangalawa ba ay "Last Trail Process as of Matching Date"
    (katapat ng Report Date group)? Ano ang pangatlo?
15. Matching Report: paano kinukuwenta ang "Payment TAT", "Type of Claim", "History Effect" (mula sa EFFECT ng RTH/Denial Reasons?),
    at "Filed Amount vs. Actual Payment Upgrade"? Saan galing ang Patient Reference No., case rates, at Health Care Professional
    (HF ICS, ICD Codes, PF Name)?
16. Matching Report: ang mga column sa "Internal Data Only" ay hindi ipapakita sa facility users — tama ba?
17. Status Trail sheet "2. Status as of matching date": ang instruction ay "exclude any status beyond June 30, 2025".
    Ang cutoff ba ay ang **Matching Date** ng run (at lumang label lang ang "June 30, 2025"), o iba pang petsa? (kaugnay ng #1)
18. Payment Details: (a) ang huling column (blangko/putol sa screenshot) ba ay TOTAL_TOT_AMNT gaya ng nasa §2?
    (b) Kapag may higit sa isang row ang isang SERIES (hal. iba't ibang TRANCHE_NUMBER), **susumahin** ba ang halaga para sa
    "Total Amount Paid", o ang pinakabagong row lang? Alin ang gagamitin para sa Check No., OR No./Date, at Mode of Payment?
    **Sagot (b): pinakabagong row lang (latest CHECK_DT), hindi sinusuma — tingnan ang §3c-bis.** Bukas pa ang (a).
19. RTH/Denial Reasons: (a) ano ang laman ng blangkong column pagkatapos ng CLAIM SERIES NUMBER? (b) Ano ang ibig sabihin ng
    mga EFFECT code (hal. P = RTH, D = Denied)? (c) Kapag maraming reason ang isang claim na may magkaibang EFFECT, alin ang
    lalabas sa table na "Claim Series Number · Effect" (at sa History Effect)?
20. MR → Matching Report: tama ba ang mapping na MR Received Date = mrRcvDate, MR Status = finalRecom (o approval?),
    Decision Release Date = dateFinalized? Kapag higit sa isang MR ang isang SERIES, ang pinakabago ba (ayon sa mrRcvDate)?
21. PARD → Matching Report: PARD Receive Date = ENTRY_DATE at Latest PARD Status = APPROVAL_SOURCE, gamit ang pinakabagong
    ENTRY_DATE bawat SERIES — tama ba?
22. PF Name → "Health Care Professional": kapag higit sa isang doktor ang isang SERIES, pagsasamahin ba (hal. hinihiwalay ng
    "; ")? At kung may HEALTH PROFESSIONAL din sa RTH/Denial Reasons, alin ang susundin?
23. Tagging / Untagging → Matching Report (Internal Data Only): (a) tama ba ang mapping na tagging date = pinakabagong
    DATE_TAGGED, Latest Tag Status = PROCESS nito, untagging date = pinakabagong DATE_UNTAGGED, Latest Untag Status = PROCESS nito?
    (b) Paano kinukuwenta ang "Issue" (hal. may tag na mas bago kaysa sa huling untag → may open issue pa)? (c) Ang "Last Date Tag"
    ba ay pareho ng tagging date?
24. ICD Codes → First/Second Case Rate: kapag dalawa (o higit) ang row ng isang SERIES, alin ang "first" at alin ang "second"
    (hal. mas mataas na TOTAL_ACR_AMOUNT = first)? Ang ipapakita ba ay ICD code, RVS code, o pareho (hal. "A09 / 90935")?
25. "As of nakaraang Report Date" (Annex A at Amount Used for Recon): kukuwentahin ba mula sa **kasalukuyang** upload ng
    Status Trail gamit ang cutoff na nakaraang Report Date (gaya ng ginagawa sa Excel), sa halip na kunin sa nakaraang run?
    Kung oo, saan galing ang petsang iyon — itinatakda ng FINMAREP sa run? (Sinasagot nito ang #13 at bahagi ng #1.)
    **Sagot: oo — ilalagay ng FINMAREP sa run, kinukuwenta mula sa parehong Status Trail upload.**
26. Mga kasong wala sa decision table ng §3c: (a) huling trail ay RTH/DENIED pero STATUS ay G (o blangko); (b) walang trail
    at STATUS ay blangko o ibang code; (c) payment row na walang anumang petsa. Pansamantalang: (a)(b) → IN PROCESS,
    (c) → bayad sa lahat ng cutoff. Tama ba? At sa Recon Amount, ang UNMAPPED ba ay ituturing na IN PROCESS?
27. Claim na nasa HF ICS (o HO ICS) as of Report Date pero ang DATE_REC ay pagkatapos ng Report Date (NOT YET FILED as of
    Report Date): pansamantalang itinuturing na IN PROCESS sa recon amount at reconciling item. Tama ba?
