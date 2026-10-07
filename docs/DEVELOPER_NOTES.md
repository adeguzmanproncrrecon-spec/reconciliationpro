# ReconciliationPro

System na papalit sa Excel reconciliation workbook ng PhilHealth (hal. "NCR NORTH – AS OF <DATE> – <HOSPITAL>.xlsx").
**Ang buong lohika ay nasa [docs/RECON_SPEC.md](docs/RECON_SPEC.md) — sundin ito.** Kapag may salungat sa code at spec, ang spec ang masusunod; kapag malabo ang spec (tingnan ang Open Questions doon), magtanong muna, huwag manghula.

## Stack
- Multi-page HTML/CSS/JS (walang framework, walang build step).
- Supabase (Postgres + Auth + RLS). **Test project lang — pekeng data lang.**

## Pagpapatakbo (local)
- **Huwag buksan ang HTML bilang file** (double-click / `file:///…`): hindi gagana ang Excel export (template fetch at
  Web Worker). I-double-click ang **`tools/serve.cmd`** → bubukas ang `http://localhost:8080/login.html`.
  Ibang port: `tools\serve.cmd -Port 8090`. Ctrl+C para itigil.
- Localhost lang ang server at allowlist ang ibinibigay (mga HTML page sa root, `js/`, `css/`, `img/`, `templates/`).
- Sa Supabase → Authentication → URL Configuration, dapat nasa **Redirect URLs** ang `http://localhost:8080/**`
  (para sa link ng forgot password at email confirmation).

## Mga file
| File | Side | Papel |
|---|---|---|
| `login.html` | pareho | Sign-in (Supabase Auth); sinusuri ang status/role at nire-redirect sa tamang shell |
| `reset-password.html` | pareho | Forgot password: humingi ng link (generic na mensahe) → bagong password mula sa email link |
| `register.html` | pareho | Pagrehistro (Facility staff: accreditation no.; PhilHealth staff: home branch) → pending |
| `a_dashboard.html` | PhilHealth | Shell (sidebar + topbar + `<iframe name="content-frame">`) |
| `a_dash.html` | PhilHealth | Dashboard (`ph_dashboard` RPC, 0028): bilang, kailangang aksyunan, status ng claims bawat branch, pinakabagong runs; link sa `a_reconciliation.html?run=` / `import.html?run=` |
| `import.html` | PhilHealth (FINMAREP lang) | Data Ingestion: gumawa ng recon run, piliin ang HF ICS, i-upload ang HO ICS / Raw Matching / Status Trail / Payment Details, at Yugto 2 (optional) |
| `a_reconciliation.html` | PhilHealth | Run matching (FINMAREP; background job via pg_cron), status ng job, Summary, Annex A, Matching Report (+ Claim History), HO ICS Recon, Unmapped processes |
| `a_accounts.html` | PhilHealth | Account management ng Branch Admin / FINMAREP approver (sa iframe) |
| `f_dashboard.html` | facility | Shell ng facility portal |
| `f_dash.html` | facility | Laman ng facility dashboard (nilo-load sa iframe ng `f_dashboard.html`) |
| `f_accounts.html` | facility | Staff account management ng Facility Admin (sa iframe) |
| `f_upload.html` | facility | Upload ng HF ICS (.xlsx → column mapping → batch RPC upload) |
| `f_reports.html` | facility | Listahan ng natapos na matching ng sariling facility → Annex A (facility version) at Matching Report |
| `js/export-xlsx.js` | pareho | Excel export: Annex A = pinupunan ang `templates/annex-a.xlsx` (mismong template ng PhilHealth: logo, format, merges) sa eksaktong cell gamit ang fflate. Ang kanang side (Summary of Status of ICS Claims, U–AD) ay ipinapakita at pinupunan sa **internal lang**; sa facility version, blangko at nakatago. Matching Report sa background worker |
| `templates/annex-a.xlsx` | — | Malinis na Annex A template (walang formula, external link, o pangalan ng tao). Gawin ulit gamit ang `tools/build-annex-template.ps1 -Src <blankong template> -Out templates/annex-a.xlsx`; kapag nagbago ang layout, i-update ang mga row/column sa `js/export-xlsx.js` (REC_ROWS, HF_ROWS, HO_ROWS, *_COLS) |
| `js/export-matching-worker.js` | pareho | Web Worker: paunti-unting kinukuha ang rows (JWT ng user → RLS) at binubuo ang Matching Report .xlsx (fflate streaming) — hindi naha-hang ang page; kaya ang 200k |
| `js/vendor/fflate-0.8.2.umd.js` | pareho | fflate 0.8.2, self-hosted; sinusuri ng worker ang SHA-384 bago gamitin (walang integrity sa `importScripts`) |
| `supabase/functions/export-matching-report/` | server | **Hindi na ginagamit** (2026-10-06): lumampas sa 2s CPU limit ng Edge Functions sa 50k+ rows. Pinalitan ng worker. |
| `f_loi.html` | facility | Letter of Intent (0029): Facility Admin ang nagsusumite (PDF/JPG/PNG ≤10 MB sa private bucket `loi`, path `<facility_id>/<uuid>.<ext>` → `submit_loi`); staff view-only; walang edit/delete — bagong LOI kapag may mali |
| `a_faciwithloi.html` / `a_facinoloi.html` | PhilHealth | Facilities with LOI (pinakabagong LOI + lahat ng LOI) / without LOI (may complete na HF ICS, walang LOI); `list_facilities_loi` RPC + `js/loi-list.js`; download sa signed URL. Ang `import.html` ay kumukuha ng default na coverage sa pinakabagong LOI |
| `a_templates.html` | PhilHealth | Templates (0031): FINMAREP ang nag-a-upload ng blankong template (.xlsx/.xls, private bucket `templates`) → `add_template`; "Visible to facilities" / Retire sa `set_template_status` (walang delete). Ang mga visible ay may download box sa `f_upload.html` |
| `a_logs.html` | PhilHealth (FINMAREP, Branch Admin) | System Logs (0032): `audit_log` na isinusulat ng mga trigger (accounts, uploads, recon run, matching, LOI, templates, settings) at ng `log_export` (export). FINMAREP = lahat; Branch Admin = home branch (account events ayon sa nakikita niya sa Accounts). Hindi mababago o mabubura |
| `a_settings.html` | PhilHealth (FINMAREP) | System settings (0033, `app_settings` + `set_app_setting`): mga posisyon ng signatory sa Annex A (blangko pa rin ang mga pangalan) |
| `f_profile.html` | facility | Facility Profile (0033, `facility_profile()`): view-only na detalye, Facility Admin, bilang ng account, pinakabagong HF ICS / LOI / recon. Walang Settings tab sa facility (desisyon ng user) |
| `my_account.html` | pareho | My Account (dropdown sa topbar): sariling detalye (view-only) at pagpapalit ng password (sinusuri muna ang kasalukuyang password; ≥8, may malaking titik at numero) |
| `js/annex-view.js` | pareho | Pagpapakita ng Annex A mula sa `annex_a()` (ginagamit ng `a_reconciliation.html` at `f_reports.html`) |
| `js/supabase-client.js` | pareho | Shared Supabase client (publishable key lang), `sbHomeFor`, `sbRoleLabel` |
| `js/auth-guard.js` | pareho | Guard sa `<head>` ng bawat protektadong page (`data-roles`); `data-user`, `data-show-for`, `data-signout`, `sbUserReady` |
| `js/accounts.js` | pareho | Logic ng `a_accounts.html` / `f_accounts.html` |
| `js/xlsx-import.js` | pareho | Shared na pagbasa ng .xlsx: header detection, Claim Series bilang text, amount, petsa (MM/DD/YYYY o serial) |
| `js/vendor/xlsx-0.20.3.full.min.js` | pareho | SheetJS 0.20.3, self-hosted na may SRI (huwag gamitin ang 0.18.5 sa cdnjs — may CVE) |
| `docs/samples/FAKE_*.xlsx` | — | Pekeng test files lang. **Huwag maglagay ng tunay na file dito.** |

- supabase-js ay naka-pin (`@2.117.2`) na may SRI hash; kopyahin ang `<script>` tag mula sa `login.html` para sa bagong page.
- Bawat bagong protektadong page (pati sa loob ng iframe): isama ang supabase-js + `js/supabase-client.js` + `js/auth-guard.js` sa `<head>`.

- Pattern: ang `*_dashboard.html` ay shell; ang mga page sa loob ay hiwalay na HTML na nilo-load sa iframe.
- `a_reports.html` (PhilHealth): listahan ng natapos na matching (branch filter, facility search, latest only) → Annex A
  (internal/facility) at Matching Report (kasama ang internal columns) + export; link sa Reconciliation.
- Wala pa (may link sa sidebar pero wala pang file): `app.js`, `img/recon-icon.png`.
  Lahat ng tab sa dalawang sidebar ay may sariling page na (2026-10-07).
- `css/`, `js/` — para sa shared na CSS/JS. Inline pa ang CSS/JS sa HTML; huwag ilipat nang hindi hinihingi.
- `supabase/migrations/` — lahat ng SQL.
- Huwag burahin o palitan ang pangalan ng mga HTML file.
## Mga user (sagot sa spec §6 #7)
- **Facility users: lahat ng PhilHealth-accredited facilities.** Multi-tenant ang system: libu-libong facility, at bawat facility user ay **sariling facility lang** ang nakikita (RLS ayon sa `facility_id` ng user sa `profiles`).
- **PhilHealth users: FINMAREP at BAS Processor** — ito ang mga position/role, hindi "admin". Huwag gumamit ng "admin" bilang pangalan ng role sa UI o DB para sa kanila.
- **Facility** — siya ang nag-a-upload ng **HF ICS** (sariling submission). Hindi siya nagma-match.
- **FINMAREP** — siya lang ang nag-a-upload ng **HO ICS** at ng PhilHealth extractions (Raw Matching, Status Trail, Payment Details, at Yugto 2 uploads). Siya ang gumagawa ng recon run at **nagti-trigger ng matching** (HF ICS ng facility vs. extraction niya). Ang matching mismo ay sa SQL/RPC.
- **BAS Processor** — **view-only**: reports at analytics lang, **pwedeng mag-export** (Excel). Walang upload, walang edit, walang pag-trigger ng matching. Ipatupad ito sa RLS/RPC (walang `insert`/`update`/`delete` policy para sa kanya), hindi lang sa pagtatago ng button sa UI.
- **Branch scope** (mapping ng user ↔ branches sa `user_branches`, pwedeng higit sa isa):
  - **FINMAREP** — nakikita ang **lahat ng branch** (para matulungan ang kasamahan). Ang branch filter ay **UI filter lang**, naka-default sa mga branch na hawak niya; hindi ito RLS restriction. **Pwede rin siyang mag-upload at mag-trigger ng matching sa kahit anong branch** (kaunti lang sila, at trabaho nila ang mag-match basta hawak nila ang raw data).
  - **BAS Processor** — **RLS-restricted** sa mga branch na naka-assign sa kanya lang.
- **Account management** (register sa `register.html` → naka-pending hanggang i-approve):
  - **Branch Admin** (pwedeng higit sa isa bawat branch) — parang BAS Processor (view-only na reports/analytics + export, sa **home branch** niya), dagdag ang account management: nag-a-approve ng BAS Processor at nagma-manage ng FINMAREP/BAS Processor na ang home branch ay branch niya, at ng Facility Admin ng mga facility sa branch niya. Siya rin ang nagtatalaga ng kapalit kapag umalis ang Facility Admin. **Hindi siya makaka-approve ng FINMAREP** (lahat ng branch ang nakikita nito). **Sariling branch lang** ang pwede niyang i-assign/alisin sa `user_branches`.
  - **FINMAREP approver** — FINMAREP (IT) na may `is_finmarep_approver = true` (IT lang ang nagse-set sa SQL editor); siya lang ang nag-a-approve ng FINMAREP accounts.
  - **Facility Admin** (**isa lang na active bawat facility**) — nag-a-approve at nagma-manage ng staff accounts ng sariling facility.
  - Bawat PhilHealth user ay may **home branch** (`profiles.branch_id`); ang `user_branches` ay ang mga branch na hawak niya.
  - Ang approver ang nag-a-assign ng role at facility/branch; hindi ito kinukuha sa registration form.
  - Pumipili ang nagrerehistro ng **position** (`profiles.requested_role`, hiling lang): FINMAREP / BAS Processor, o Facility Staff / Facility Admin. Ang pending request ay makikita lang ng tamang approver (FINMAREP → FINMAREP approver; BAS Processor at Facility Admin → Branch Admin; Facility Staff → Facility Admin), at ang approval ay dapat tugma sa hiniling na role.
  - Ang Branch Admin accounts ay ginagawa muna ng IT sa SQL editor.
- **Export sa Excel:** PhilHealth roles at **facility** (Annex A facility version + Matching Report ng sariling facility). Sa Annex A,
  ang "Prepared by" ay pangalan at role ng nag-export; blangko ang Reviewed by / Certified Correct / Acknowledged by.
- Hindi pa final: kung may hiwalay na accountant role.

## Claim Series (matching key)
- Normalize: tanggalin ang lahat ng non-digit, kunin ang unang 13 digits.
  SQL: `left(regexp_replace(x, '\D', '', 'g'), 13)`
- Kulang sa 13 digits o blangko → "Invalid Claim Series", hindi ima-match.
- **Laging `text`** — sa DB, sa JS, at sa pag-parse ng CSV/Excel (iwas scientific notation at pagkawala ng leading zeros). Huwag kailanman i-convert sa number.

## Petsa sa UI
- **Laging MM/DD/YYYY** sa pagpapakita at sa pag-input (text input na may placeholder "MM/DD/YYYY", hindi `<input type="date">` dahil sumusunod iyon sa locale ng browser). Sa DB at RPC: ISO `YYYY-MM-DD`. Huwag gumamit ng `toLocaleDateString()` / `toLocaleString()` para sa petsa.

## Rules
1. **Laging naka-RLS.** Bawat bagong table ay may `enable row level security` at policies sa parehong migration.
2. **Huwag ilagay ang `service_role` key** (o anumang secret key) sa frontend o sa repo. Publishable/anon key lang ang nasa browser.
3. **Huwag basahin o i-edit ang `.env`** — kahit sa shell (`Get-Content`, `cat`, atbp.).
4. **Lahat ng SQL ay i-save muna sa `supabase/migrations/`** bago i-apply, may numero: `0001_<pangalan>.sql`, `0002_<pangalan>.sql`, …
5. **Matching sa SQL/RPC, hindi sa browser.** Ang browser ay nag-a-upload at nagpapakita lang. Ang mabibigat na proseso (hal. matching) ay **background job** (`recon_matches` queue + `pg_cron` → `process_matching_queue()` → `do_matching()`), dahil 8s lang ang statement_timeout ng `authenticated`.
6. **Batch uploads** (200k+ rows bawat upload) — huwag isang malaking insert, huwag i-load lahat sa memory kung kaya.
7. **Pagination** sa lahat ng listahan/table; walang full load ng dataset sa browser.
8. **`textContent`** (o escape) para sa anumang user/uploaded data — hindi `innerHTML` na may raw na data.
9. **Maliit na edits.** Ipaliwanag muna ang plano bago gumawa ng malaking pagbabago.
10. **Huwag mag-`DROP` / `DELETE` / `TRUNCATE`** (o anumang mapanirang SQL) nang walang tahasang pahintulot ng user.
11. **Huwag kailanman maglagay ng tunay na PhilHealth o facility data** — pekeng pangalan, claim series, at halaga lang, sa code, seed, test, o docs.

## Susunod na gagawin (huling update: 2026-10-07)
Tapos at naka-apply ang migrations 0001–0033 (0032: System Logs / audit_log; 0033: Facility Profile + System settings) (0031: Templates) (0030: ayos sa recursion ng LOI upload policy — huwag mag-query ng
`storage.objects` sa loob ng policy ng `storage.objects`; gumamit ng security definer function) (0028: `ph_dashboard`; 0029: Letter of Intent — `facility_lois`, bucket `loi`,
`submit_loi`, `list_facilities_loi`; max 20 LOI upload bawat facility bawat 24 oras. Hindi pa nasusubukan sa browser). (0025/0027: kinukuwenta at sine-save ang Annex A at Summary sa matching job →
`recon_annex`, `recon_summary_cache`; instant na ang `annex_a` at `match_summary`. Mabagal ang disk ng Free plan sa unang
basa, kaya lahat ng mabigat na aggregate ay dapat sa matching job, hindi habang naghihintay ang user).
Kapag may cleanup/reset ng recon_matches: burahin muna ang `recon_annex` at `recon_summary_cache` (FK). 0021: 30 minutong statement_timeout ng matching job (2 min ang default ng server).
0023: single-pass `do_matching` (lahat ng column sa INSERT, walang buong-table UPDATE — dati napupuno ang disk), at dalawang cron
job: `claim-matching-job` (queued → running, nakikita agad) at `process-matching-queue`. 0024: reset ng test data (2026-10-06).
**Free plan = 500 MB database** — hindi kakasya ang 200k test (~685 MB); gamitin ang `FAKE_VOL50K_*` (50k: ~2 min matching).
Nananatili ang resulta ng bawat lumang matching (wala pang retention policy) — mabilis maubos ang espasyo sa paulit-ulit na run. (accounts, HF ICS upload, recon runs + extraction uploads, matching bilang pg_cron
background job, `match_summary`, `annex_a(match, internal)`, NOT YET FILED). Kulang pa:
1. ~~Annex A tab sa `a_reconciliation.html`~~ — tapos (internal/facility toggle); hindi pa nasusubukan sa browser.
2. ~~Reports page ng facility (`f_reports.html`)~~ — tapos (2026-10-06); hindi pa nasusubukan sa browser.
3. ~~Export sa Excel~~ — tapos: Annex A = pinupunang template (2026-10-07); Matching Report sa Web Worker (keyset
   pagination, fflate streaming) — pinalitan ang Edge Function (2026-10-06). Hindi pa nasusubukan sa browser.
4. ~~Yugto 2~~ — tapos (2026-10-06): 0016 (7 upload tables, optional), 0017 (`do_matching_yugto2` na tinatawag ng
   `process_matching_queue` pagkatapos ng `do_matching`; facility-visible na columns sa `recon_hf_results`; Tagging/Untagging
   sa `recon_hf_internal` — PhilHealth lang; `claim_history(run, series)` — PhilHealth lang). Slots sa `import.html`,
   columns sa `a_reconciliation.html` / `f_reports.html` / Edge Function (v3), Claim History panel. Hindi pa nasusubukan sa browser;
   test file: `docs/samples/FAKE_EDGE_yugto2_TEST-HOSP-0001.xlsx` (FAKE_TEST_PLAN.md §A3). 0018: Issue (OPEN/RESOLVED) at Payment TAT (bawas ang araw na may issue) sa `recon_hf_internal`.
   0019: Type of Claim (bagong upload na `claim_type`, PhilHealth lang), Patient Reference No. (optional na column sa HF ICS),
   Filed vs Actual Payment Upgrade, listahan ng na-flag na value sa upload preview (#3).
   Sagot na ang lahat ng tanong sa §6 na kailangan para sa Matching Report (tingnan ang §3c-quater).
   0020: Annex A balanse sa COUNT at AMOUNT (internal at facility version); breakdown = "Annex A line" columns sa Matching
   Report / HO ICS Recon (`do_matching_annex`, tinatawag pagkatapos ng `do_matching_yugto2`). Edge Function v7.
5. Bukas pa: tingnan ang `docs/SYSTEM_REVIEW.html` (technical T1–T9, proseso P1–P8). Sa RECON_SPEC §6, nasagot na ang
   karamihan sa §3c-ter / §3c-quater; pansamantala pa ang #21 (PARD), #23 (Tagging/Untagging) at #19a/b.
Test data: `docs/samples/FAKE_*.xlsx` + `FAKE_TEST_PLAN.md`. Test run: TEST-HOSP-0001 (Sample General Hospital).
