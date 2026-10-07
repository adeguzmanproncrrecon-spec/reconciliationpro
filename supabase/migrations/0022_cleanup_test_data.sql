-- 0022_cleanup_test_data.sql
-- ISANG BESES LANG, TEST PROJECT LANG (pekeng data). Tahasang pinahintulutan ng user (2026-10-06) dahil napuno ang disk
-- ("No space left on device") habang nagma-match ng 200k volume test.
-- Binubura:
--   1) Ang laman (rows) ng 4 na DISCARDED volume uploads sa EDGE run 587dbc72 (10/05/2026). Nananatili ang talaan sa
--      run_uploads (pangalan ng file, bilang ng row, status = discarded).
--   2) Ang lumang matching eb097c95 (10/05/2026 06:50, hindi current) ng EDGE run at lahat ng resulta nito.
-- HINDI ginagalaw: ang current na matching ng EDGE run, ang bagong volume uploads (run 9d7ca0d6), HF ICS, at accounts.
-- Pagkatapos: VACUUM (ANALYZE) ng mga table (hiwalay na patakbuhin; hindi pwede sa loob ng transaction).

-- 1) Laman ng discarded volume uploads ng EDGE run
delete from public.status_trail    where upload_id in (select id from public.run_uploads
  where run_id = '587dbc72-4b8a-4bd0-9c59-56a84f4b8dd4' and status = 'discarded' and kind = 'status_trail'    and file_name like 'FAKE_VOLUME_%');
delete from public.raw_claims      where upload_id in (select id from public.run_uploads
  where run_id = '587dbc72-4b8a-4bd0-9c59-56a84f4b8dd4' and status = 'discarded' and kind = 'raw_matching'    and file_name like 'FAKE_VOLUME_%');
delete from public.ho_ics_rows     where upload_id in (select id from public.run_uploads
  where run_id = '587dbc72-4b8a-4bd0-9c59-56a84f4b8dd4' and status = 'discarded' and kind = 'ho_ics'          and file_name like 'FAKE_VOLUME_%');
delete from public.payment_details where upload_id in (select id from public.run_uploads
  where run_id = '587dbc72-4b8a-4bd0-9c59-56a84f4b8dd4' and status = 'discarded' and kind = 'payment_details' and file_name like 'FAKE_VOLUME_%');

-- 2) Lumang matching eb097c95 (hindi current) at ang mga resulta nito
delete from public.recon_hf_internal    where match_id = 'eb097c95-09b8-4014-ba2f-3f881f6a458c';
delete from public.recon_match_unmapped where match_id = 'eb097c95-09b8-4014-ba2f-3f881f6a458c';
delete from public.recon_hf_results     where match_id = 'eb097c95-09b8-4014-ba2f-3f881f6a458c';
delete from public.recon_ho_results     where match_id = 'eb097c95-09b8-4014-ba2f-3f881f6a458c';
delete from public.recon_matches        where id = 'eb097c95-09b8-4014-ba2f-3f881f6a458c' and not is_current;
