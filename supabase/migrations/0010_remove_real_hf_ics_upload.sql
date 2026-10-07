-- 0010_remove_real_hf_ics_upload.sql
-- Pagbura ng HF ICS upload na may TUNAY na data na aksidenteng na-upload sa test project (rule 11).
-- Tahasang pinahintulutan ng user (rule 10) noong 2026-10-05.
-- Tinutukoy ayon sa facility (TEST-HOSP-0001) at bilang ng row (2,712) — walang tunay na identifier sa file na ito.

-- Siguraduhing walang recon run na gumagamit nito (kung mayroon, alisin ang link)
update public.recon_runs r
   set hf_submission_id = null
 where r.hf_submission_id in (
   select s.id from public.hf_ics_submissions s
     join public.facilities f on f.id = s.facility_id
    where f.accreditation_no = 'TEST-HOSP-0001' and s.row_count = 2712);

delete from public.hf_ics_rows r
 using public.hf_ics_submissions s, public.facilities f
 where r.submission_id = s.id and f.id = s.facility_id
   and f.accreditation_no = 'TEST-HOSP-0001' and s.row_count = 2712;

delete from public.hf_ics_submissions s
 using public.facilities f
 where f.id = s.facility_id
   and f.accreditation_no = 'TEST-HOSP-0001' and s.row_count = 2712;
