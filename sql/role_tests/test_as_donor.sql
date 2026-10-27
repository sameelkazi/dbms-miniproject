-- Run as the DONOR role:  mysql -u fr_donor -pDonor@123 -t --force < test_as_donor.sql
USE food_rescue;
SET @demo_now = '2026-11-05 20:30:00';
SELECT CURRENT_USER() AS logged_in_as;

SELECT 'D1. ALLOWED: wastage dashboard' AS test;
SELECT donor_name, item_name, batch_no, quantity, urgency FROM expiring_soon;

SELECT 'D2. ALLOWED: demand the donor is missing' AS test;
SELECT * FROM unmet_demand;

SELECT 'D3. ALLOWED: receive a new batch' AS test;
INSERT INTO Food_Batch (donor_id, item_id, batch_no, prepared_at, best_before, quantity, listed_at)
VALUES (1, 6, 'GS-BR-1105', '2026-11-05 18:00:00', '2026-11-07 18:00:00', 14, '2026-11-05 20:30:00');

SELECT 'D4. ALLOWED: adjust stock through the audited procedure' AS test;
CALL update_batch_quantity(1, 6, 'GS-BR-1105', 12, 'WASTED');

SELECT 'D5. ALLOWED: change its own price' AS test;
UPDATE Listing SET price_per_unit = 19.00 WHERE donor_id = 1 AND item_id = 6;

SELECT 'D6. DENIED: delete a listing' AS test;              -- ERROR 1142 DELETE command denied
DELETE FROM Listing WHERE donor_id = 1 AND item_id = 6;

SELECT 'D7. DENIED: edit stock directly, skipping the audit procedure' AS test;   -- ERROR 1142 UPDATE denied
UPDATE Food_Batch SET quantity = 500 WHERE batch_no = 'GS-BR-1105';

SELECT 'D8. DENIED: verify itself' AS test;                 -- ERROR 1142 UPDATE command denied
UPDATE Donor SET status = 'VERIFIED' WHERE donor_id = 5;

SELECT 'D9. DENIED: read receivers personal data' AS test;  -- ERROR 1142 SELECT command denied
SELECT * FROM Receiver;
