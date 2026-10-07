// Edge Function: export-matching-report
// Bumubuo ng Matching Report (.xlsx) sa server at ipinapadala nang paunti-unti (streaming).
// - Ginagamit ang JWT ng user (walang service role key) → parehong RLS: facility = sariling facility lang.
// - Claim Series ay text (inline string); petsa ay Excel date na mm/dd/yyyy; halaga ay #,##0.00.
// Input (POST JSON): { "match_id": "<uuid>" }
import { createClient } from "npm:@supabase/supabase-js@2.117.2";
import { Zip, ZipDeflate, strToU8 } from "npm:fflate@0.8.2";

const PAGE = 1000;

// [grupo, header, field, uri]  (RECON_SPEC §4a)
type ColType = "text" | "int" | "money" | "date" | "bool";
const COLS: [string, string, string, ColType][] = [
  ["HEALTH FACILITY DATA", "ITEM NO.", "item_no", "int"],
  ["HEALTH FACILITY DATA", "PATIENT REFERENCE NO.", "patient_ref", "text"],
  ["HEALTH FACILITY DATA", "FIRST CASE RATE (ICD10/RVS)", "first_case_rate", "text"],
  ["HEALTH FACILITY DATA", "SECOND CASE RATE (ICD10/RVS)", "second_case_rate", "text"],
  ["HEALTH FACILITY DATA", "HEALTH CARE PROFESSIONAL", "health_professional", "text"],
  ["CLAIM DETAILS", "CLAIM SERIES NUMBER", "claim_series", "text"],
  ["CLAIM DETAILS", "CLAIM SERIES (AS IN HF ICS)", "claim_series_raw", "text"],
  ["CLAIM DETAILS", "MEMBER'S PIN", "member_id", "text"],   // mula sa MECNO ng Raw Matching
  ["CLAIM DETAILS", "PATIENT'S LAST NAME", "pat_lname", "text"],
  ["CLAIM DETAILS", "PATIENT'S FIRST NAME", "pat_fname", "text"],
  ["CLAIM DETAILS", "PATIENT'S MIDDLE NAME", "pat_mname", "text"],
  ["CLAIM DETAILS", "MEMBER'S LAST NAME", "mem_lname", "text"],
  ["CLAIM DETAILS", "MEMBER'S FIRST NAME", "mem_fname", "text"],
  ["CLAIM DETAILS", "MEMBER'S MIDDLE NAME", "mem_mname", "text"],
  ["CLAIM DETAILS", "ADMISSION DATE", "date_adm", "date"],
  ["CLAIM DETAILS", "DISCHARGE DATE", "date_dis", "date"],
  ["CLAIM DETAILS", "FILING DATE", "date_filed", "date"],
  ["CLAIM DETAILS", "LATEST RECONSIDERED DATE", "date_recon", "date"],
  ["CLAIM DETAILS", "LATEST REFILING DATE", "last_refiled", "date"],
  ["CLAIM DETAILS", "CLAIMS FILING TAT (DISCHARGE TO FILING)", "filing_tat", "int"],
  ["CLAIM DETAILS", "CLAIMS REFILING TAT", "refiling_tat", "int"],
  ["STATUS DETAILS", "STATUS AS OF {rd}", "status_rd", "text"],
  ["STATUS DETAILS", "LAST TRAIL DATE AS OF {rd}", "trail_date_rd", "date"],
  ["STATUS DETAILS", "LAST TRAIL PROCESS AS OF {rd}", "trail_process_rd", "text"],
  ["STATUS DETAILS", "STATUS AS OF {pd}", "status_pd", "text"],
  ["STATUS DETAILS", "STATUS AS OF MATCHING DATE", "status_md", "text"],
  ["STATUS DETAILS", "LAST TRAIL DATE AS OF MATCHING DATE", "trail_date_md", "date"],
  ["STATUS DETAILS", "LAST TRAIL PROCESS AS OF MATCHING DATE", "trail_process_md", "text"],
  ["STATUS DETAILS", "STATUS (G/D/P)", "raw_status", "text"],
  ["STATUS DETAILS", "ALL CASE RATE", "all_case_rate", "money"],
  ["PAYMENT DETAILS", "PHIC PAYMENT PROCESSED DATE", "latest_check_dt", "date"],
  ["PAYMENT DETAILS", "BANK ADVISE DATE", "bank_advise_date", "date"],
  ["PAYMENT DETAILS", "CHECK NO.", "check_no", "text"],
  ["PAYMENT DETAILS", "CHECK DATE", "check_dt", "date"],
  ["PAYMENT DETAILS", "IRM POPULATION?", "is_irm", "bool"],
  ["PAYMENT DETAILS", "DCPM POPULATION?", "is_dcpm", "bool"],
  ["PAYMENT DETAILS", "PAYMENT RECOVERY NO.", "pr_no", "text"],
  ["PAYMENT DETAILS", "OR NO.", "or_no", "text"],
  ["PAYMENT DETAILS", "OR DATE", "or_date", "date"],
  ["PAYMENT DETAILS", "MODE OF PAYMENT", "mode_of_payment", "text"],
  ["PAYMENT DETAILS", "PAYMENT STATUS", "payment_status", "text"],
  ["PAYMENT DETAILS", "TOTAL AMOUNT PAID", "total_amount_paid", "money"],
  ["PAYMENT DETAILS", "ICS AMT (AMOUNT ON HF BOOKS)", "ics_amount", "money"],
  ["PAYMENT DETAILS", "AMOUNT ON PHIC BOOKS", "amount_on_phic_books", "money"],
  ["PAYMENT DETAILS", "AMOUNT USED FOR RECON (AS OF {rd})", "amount_used_rd", "money"],
  ["PAYMENT DETAILS", "AMOUNT USED FOR RECON (AS OF {pd})", "amount_used_pd", "money"],
  ["PAYMENT DETAILS", "AMOUNT USED FOR RECON (AS OF MATCHING DATE)", "amount_used_md", "money"],
  ["PAYMENT DETAILS", "FILED AMOUNT VS. ACTUAL PAYMENT UPGRADE", "filed_vs_actual", "money"],
  ["HF ICS RECON", "RECON AMOUNT", "recon_amount", "money"],
  ["HF ICS RECON", "UPGRADE (DOWNGRADE)", "upgrade_downgrade", "money"],
  ["HF ICS RECON", "ALSO ON ICS OF HO?", "in_ho_ics", "bool"],
  ["HF ICS RECON", "DUPLICATE CHECK", "is_duplicate", "bool"],
  ["HF ICS RECON", "RECONCILING ITEM", "reconciling_item", "text"],
  ["ANNEX A (BREAKDOWN)", "ANNEX A LINE – HEALTH FACILITY", "annex_hf_line", "text"],
  ["ANNEX A (BREAKDOWN)", "ANNEX A LINE – PHILHEALTH", "annex_ph_line", "text"],
  ["RTH / DENIED", "RTH / DENIED CONTROL NUMBER", "ctrl_no", "text"],
  ["RTH / DENIED", "CONTROL NUMBER ISSUANCE DATE", "ctrl_dt", "date"],
  ["RTH / DENIED", "DATE RTH", "date_rth", "date"],
  ["RTH / DENIED", "DATE DENIED", "date_denied", "date"],
  ["RTH / DENIED", "HISTORY EFFECT", "history_effect", "text"],
  ["MOTION FOR RECONSIDERATION", "MR RECEIVED DATE", "mr_rcv_date", "date"],
  ["MOTION FOR RECONSIDERATION", "MR STATUS", "mr_status", "text"],
  ["MOTION FOR RECONSIDERATION", "DECISION RELEASE DATE", "mr_decision_date", "date"],
  ["APPEALS", "PARD RECEIVE DATE", "pard_rcv_date", "date"],
  ["APPEALS", "LATEST PARD STATUS", "pard_status", "text"],
];

// Internal Data Only (RECON_SPEC §4a) — mula sa recon_hf_internal; PhilHealth lang (hindi isinasama para sa facility)
const INTERNAL_COLS: [string, string, string, ColType][] = [
  ["INTERNAL DATA ONLY", "TYPE OF CLAIM", "type_of_claim", "text"],
  ["INTERNAL DATA ONLY", "PROCESS/POLICY ISSUE TAGGING (TAGGING DATE)", "tag_date", "date"],
  ["INTERNAL DATA ONLY", "LATEST TAG STATUS", "tag_status", "text"],
  ["INTERNAL DATA ONLY", "PROCESS/ISSUE RESOLUTION (UNTAGGING DATE)", "untag_date", "date"],
  ["INTERNAL DATA ONLY", "LATEST UNTAG STATUS", "untag_status", "text"],
  ["INTERNAL DATA ONLY", "ISSUE", "issue", "text"],
  ["INTERNAL DATA ONLY", "LAST DATE TAG", "tag_date", "date"],
  ["INTERNAL DATA ONLY", "PAYMENT TAT (DAYS, LESS DAYS ON ISSUE)", "payment_tat", "int"],
  ["INTERNAL DATA ONLY", "DAYS ON ISSUE", "days_on_issue", "int"],
];

// ---------- helpers ----------
// Mga address ng app na pinapayagan (idagdag ang hosting URL sa ALLOWED_ORIGINS secret, comma-separated)
const ALLOWED_ORIGINS = new Set(
  ["http://127.0.0.1:5500", "http://localhost:5500"].concat(
    (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean)),
);
function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ALLOWED_ORIGINS.has(origin) ? origin : "null",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Expose-Headers": "Content-Disposition",
    "Vary": "Origin",
  };
}
function json(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders(req), "Content-Type": "application/json" } });
}
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// XML escape + alisin ang mga character na bawal sa XML (control chars, U+FFFE/U+FFFF, solong surrogate)
function esc(v: string): string {
  return v.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g, "")
    .replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
function colLetter(c: number): string {
  let s = "", n = c + 1;
  while (n > 0) { const m = (n - 1) % 26; s = String.fromCharCode(65 + m) + s; n = Math.floor((n - m - 1) / 26); }
  return s;
}
function mdy(d: string | null): string {
  if (!d) return "";
  const p = d.slice(0, 10).split("-");
  return `${p[1]}/${p[2]}/${p[0]}`;
}
// "YYYY-MM-DD" → Excel serial (1900 date system)
function serial(d: string): number {
  const p = d.slice(0, 10).split("-").map(Number);
  return (Date.UTC(p[0], p[1] - 1, p[2]) - Date.UTC(1899, 11, 30)) / 86400000;
}
// Styles: 0 = default, 1 = date mm/dd/yyyy, 2 = pera #,##0.00, 3 = bold (header)
function cell(ref: string, v: unknown, type: string): string {
  if (v === null || v === undefined || v === "") return "";
  if (type === "date" || type === "money" || type === "int") {
    const n = type === "date" ? serial(String(v)) : Number(v);
    if (!Number.isFinite(n)) return "";   // huwag isulat ang NaN (sisira sa file)
    return `<c r="${ref}"${type === "date" ? ' s="1"' : type === "money" ? ' s="2"' : ""}><v>${n}</v></c>`;
  }
  if (type === "bool") return `<c r="${ref}" t="inlineStr"><is><t>${v ? "TRUE" : "FALSE"}</t></is></c>`;
  return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${esc(String(v))}</t></is></c>`;
}
function textCell(ref: string, v: string, bold = false): string {
  return `<c r="${ref}" t="inlineStr"${bold ? ' s="3"' : ""}><is><t xml:space="preserve">${esc(v)}</t></is></c>`;
}

const STATIC_FILES: Record<string, string> = {
  "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
  "_rels/.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
  "xl/workbook.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="MATCHING REPORT" sheetId="1" r:id="rId1"/></sheets></workbook>',
  "xl/_rels/workbook.xml.rels": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
  "xl/styles.xml": '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="2"><numFmt numFmtId="164" formatCode="mm/dd/yyyy"/><numFmt numFmtId="165" formatCode="#,##0.00"/></numFmts><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>',
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "Method not allowed" });

  const auth = req.headers.get("Authorization");
  if (!auth) return json(req, 401, { error: "Not signed in" });
  let body: { match_id?: string };
  try { body = await req.json(); } catch { return json(req, 400, { error: "Invalid JSON" }); }
  const matchId = String(body.match_id ?? "");
  if (!UUID_RE.test(matchId)) return json(req, 400, { error: "Invalid match_id" });

  // Client na may JWT ng user → RLS ang nagpapasya kung ano ang makikita
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: m, error: mErr } = await sb.from("recon_matches")
    .select("id, facility_id, status, report_date, prev_report_date, matching_date")
    .eq("id", matchId).eq("status", "done").maybeSingle();
  if (mErr) { console.error("recon_matches:", mErr.message); return json(req, 500, { error: "Export failed" }); }
  if (!m) return json(req, 404, { error: "Report not found" });

  const { data: fac } = await sb.from("facilities").select("name, accreditation_no").eq("id", m.facility_id).maybeSingle();
  const { count } = await sb.from("recon_hf_results").select("id", { count: "exact", head: true }).eq("match_id", m.id);

  // PhilHealth user → kasama ang Internal Data Only (RLS rin ang nagbabantay sa recon_hf_internal)
  const { data: isPh } = await sb.rpc("app_user_is_philhealth");
  const internal = isPh === true;

  const baseCols = COLS.filter(([, , f]) => (f !== "status_pd" && f !== "amount_used_pd") || m.prev_report_date);
  const cols = internal ? baseCols.concat(INTERNAL_COLS) : baseCols;
  const label = (t: string) => t.replace("{rd}", mdy(m.report_date)).replace("{pd}", mdy(m.prev_report_date));
  const fields = baseCols.map(([, , f]) => f).join(", ");
  const total = count ?? 0;
  const lastRow = 6 + total;
  const fileName = `MATCHING REPORT - ${fac?.accreditation_no ?? ""} - AS OF ${mdy(m.report_date).replace(/\//g, "-")}.xlsx`
    .replace(/[^A-Za-z0-9 ._-]/g, "_");

  // Pull-based: kinukuha ang susunod na page lang kapag humingi ang stream (backpressure).
  // Keyset pagination sa item_no (unique bawat match) — hindi bumabagal tulad ng OFFSET.
  let zip: Zip, sheet: ZipDeflate, controllerRef: ReadableStreamDefaultController<Uint8Array>;
  let lastItem = 0, r = 7, finished = false;
  const put = (s: string) => sheet.push(strToU8(s));

  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controllerRef = controller;
      zip = new Zip((err, chunk, final) => {
        if (err) { controller.error(err); return; }
        controller.enqueue(chunk);
        if (final) controller.close();
      });
      for (const [name, content] of Object.entries(STATIC_FILES)) {
        const f = new ZipDeflate(name, { level: 6 });
        zip.add(f);
        f.push(strToU8(content), true);
      }
      sheet = new ZipDeflate("xl/worksheets/sheet1.xml", { level: 6 });
      zip.add(sheet);
      put('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
      put(`<dimension ref="A1:${colLetter(cols.length - 1)}${lastRow}"/>`);
      put("<sheetViews><sheetView workbookViewId=\"0\"><pane xSplit=\"6\" ySplit=\"6\" topLeftCell=\"G7\" activePane=\"bottomRight\" state=\"frozen\"/></sheetView></sheetViews>");
      put("<cols>" + cols.map(([, , , t], i) => `<col min="${i + 1}" max="${i + 1}" width="${t === "text" ? 20 : 15}" customWidth="1"/>`).join("") + "</cols>");
      put("<sheetData>");
      put(`<row r="1">${textCell("A1", "NAME OF HEALTH FACILITY", true)}${textCell("B1", fac?.name ?? "")}</row>`);
      put(`<row r="2">${textCell("A2", "REPORT DATE", true)}${cell("B2", m.report_date, "date")}</row>`);
      put(`<row r="3">${textCell("A3", "MATCHING DATE", true)}${cell("B3", m.matching_date, "date")}</row>`);
      put(`<row r="5">` + cols.map(([g], i) => (i === 0 || cols[i - 1][0] !== g) ? textCell(`${colLetter(i)}5`, g, true) : "").join("") + "</row>");
      put(`<row r="6">` + cols.map(([, hdr], i) => textCell(`${colLetter(i)}6`, label(hdr), true)).join("") + "</row>");
    },
    async pull() {
      if (finished) return;
      try {
        const { data, error } = await sb.from("recon_hf_results").select(fields)
          .eq("match_id", m.id).gt("item_no", lastItem).order("item_no").limit(PAGE);
        if (error) throw error;
        const rows = data as Record<string, unknown>[];
        if (internal && rows.length) {
          const { data: ins, error: iErr } = await sb.from("recon_hf_internal")
            .select("item_no, tag_date, tag_status, untag_date, untag_status, issue, days_on_issue, payment_tat, type_of_claim").eq("match_id", m.id)
            .gte("item_no", Number(rows[0].item_no)).lte("item_no", Number(rows[rows.length - 1].item_no));
          if (iErr) throw iErr;
          const byItem = new Map((ins ?? []).map((x) => [Number(x.item_no), x]));
          for (const row of rows) Object.assign(row, byItem.get(Number(row.item_no)) ?? {});
        }
        let xml = "";
        for (const row of rows) {
          xml += `<row r="${r}">` + cols.map(([, , f, t], i) => cell(`${colLetter(i)}${r}`, row[f], t)).join("") + "</row>";
          r++;
          lastItem = Number(row.item_no);
        }
        if (xml) put(xml);
        if (data.length < PAGE) {
          finished = true;
          put("</sheetData></worksheet>");
          sheet.push(new Uint8Array(0), true);
          zip.end();
        }
      } catch (e) {
        finished = true;
        console.error("export rows:", e instanceof Error ? e.message : e);
        controllerRef.error(new Error("Export failed"));
      }
    },
  });

  return new Response(stream, {
    headers: {
      ...corsHeaders(req),
      "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "Content-Disposition": `attachment; filename="${fileName.replace(/"/g, "")}"`,
      "Cache-Control": "no-store",
    },
  });
});
