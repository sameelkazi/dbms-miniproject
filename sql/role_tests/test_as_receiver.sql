-- Run as the RECEIVER role:  mysql -u fr_receiver -pReceiver@123 -t --force < test_as_receiver.sql
USE food_rescue;
SET @demo_now = '2026-11-05 20:30:00';
SELECT CURRENT_USER() AS logged_in_as;

SELECT 'R1. ALLOWED: browse the public listing' AS test;
SELECT donor_name, item_name, price_per_unit, availability FROM public_listing WHERE item_id = 1;

SELECT 'R2. ALLOWED: search for the nearest donors' AS test;
CALL find_nearest_donors(1, 19.121500, 72.834800, 5, 5);

SELECT 'R3. DENIED: read hidden batch stock' AS test;      -- ERROR 1142 SELECT command denied
SELECT * FROM Food_Batch;

SELECT 'R4. DENIED: read another table directly' AS test;  -- ERROR 1142
SELECT * FROM Receiver;

SELECT 'R5. DENIED: edit a price' AS test;                  -- ERROR 1142 UPDATE command denied
UPDATE Listing SET price_per_unit = 0 WHERE donor_id = 2;

SELECT 'R6. DENIED: call a donor-only procedure' AS test;   -- ERROR 1370 execute command denied
CALL update_batch_quantity(2, 1, 'SR-BI-A', 999, 'ADJUSTED');

SELECT 'R7. ALLOWED: reserve a basket (Sneha, individual, 4 units)' AS test;
CALL reserve_basket(5, 4, 4, 4, NULL, NULL, NULL, NULL);
