-- Run as the ADMIN role:  mysql -u fr_admin -pAdmin@123 -t --force < test_as_admin.sql
USE food_rescue;
SET @demo_now = '2026-11-05 20:30:00';
SELECT CURRENT_USER() AS logged_in_as;

SELECT 'A1. ALLOWED: read everything' AS test;
SELECT donor_id, name, status FROM Donor ORDER BY donor_id;

SELECT 'A2. ALLOWED: verify the pending donor' AS test;
UPDATE Donor SET status = 'VERIFIED', verified_by = 2, verified_at = '2026-11-05 20:30:00' WHERE donor_id = 5;
SELECT donor_id, name, status, verified_by FROM Donor WHERE donor_id = 5;

SELECT 'A3. DENIED: change anything else on Donor (column-level privilege)' AS test;   -- ERROR 1143 UPDATE denied to column
UPDATE Donor SET phone = '0000000000' WHERE donor_id = 5;

SELECT 'A4. DENIED: delete a donor' AS test;               -- ERROR 1142 DELETE command denied
DELETE FROM Donor WHERE donor_id = 5;

SELECT 'A5. DENIED: touch stock' AS test;                  -- ERROR 1142 UPDATE command denied
UPDATE Food_Batch SET quantity = 0 WHERE donor_id = 1;

SELECT 'A6. ALLOWED: run the expiry sweep' AS test;
CALL release_expired_reservations();
