-- 0024_reset_test_data.sql
-- ISANG BESES LANG, TEST PROJECT LANG (pekeng data). Tahasang pinahintulutan ng user (2026-10-06): burahin ang lahat ng
-- TEST DATA para magkasya ang 50k na volume test sa Free plan (500 MB).
-- Binubura: lahat ng HF ICS uploads, recon runs, extraction at Yugto 2 uploads, matching jobs at resulta.
-- HINDI ginagalaw: accounts (auth.users, profiles), branches, facilities, user_branches, process_status_map,
-- functions / RLS / cron.
-- TRUNCATE na walang CASCADE: papalya kapag may ibang table na tumuturo sa mga ito (hindi madadamay ang iba).

truncate table
  public.recon_hf_internal,
  public.recon_match_unmapped,
  public.recon_hf_results,
  public.recon_ho_results,
  public.recon_matches,
  public.ho_ics_rows,
  public.raw_claims,
  public.status_trail,
  public.payment_details,
  public.rth_reasons,
  public.mr_records,
  public.pard_records,
  public.pf_names,
  public.issue_tags,
  public.issue_untags,
  public.icd_codes,
  public.claim_types,
  public.run_uploads,
  public.recon_runs,
  public.hf_ics_rows,
  public.hf_ics_submissions;
