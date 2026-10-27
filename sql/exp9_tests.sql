-- =====================================================================
-- Surplus Food Rescue | Exp 9 | Testing & verification
-- Run exp7_schema_and_data.sql and exp9_programming.sql first.
-- Each block says what you should see. Take your terminal screenshots from here.
-- Run:  mysql -u root -p -t < exp9_tests.sql        (-t prints boxed tables)
-- =====================================================================
USE food_rescue;
SET @demo_now = '2026-11-05 20:30:00';      -- freeze the clock: Thursday 8:30 PM

SELECT '1. Functions' AS test;
-- Expect: fn_now = 2026-11-05 20:30:00 | 45.00 (25% off still valid) | 80.00 (discount ended yesterday)
--         | 35 units across two batches | URGENT (22:00 is within 2 hours)
SELECT fn_now()                                                      AS clock,
       fn_final_price(60.00, 25, '2026-11-05 21:30:00')              AS price_valid_discount,
       fn_final_price(80.00, 10, '2026-11-04 23:00:00')              AS price_expired_discount,
       fn_available_units(2, 1)                                      AS biryani_units_spice_route,
       fn_urgency('2026-11-05 22:00:00')                             AS urgency_22h;

SELECT '2. public_listing: receivers see price + availability, never batches' AS test;
-- Expect: only VERIFIED donors (no Goregaon / Santacruz); Midnight Bakehouse Veg Sandwich = Sold Out
SELECT * FROM public_listing WHERE item_id IN (1, 11) ORDER BY item_id, donor_id;

SELECT '3. donor_open_now: who is open at 8:30 PM Thursday' AS test;
-- Expect: Gulab, Spice Route, Midnight Bakehouse, Juhu. NOT Fresh Basket (opens 9 PM), not pending/rejected.
SELECT * FROM donor_open_now;

SELECT '4. find_nearest_donors: Veg Biryani within 5 km of Andheri West' AS test;
-- Expect: Spice Route (~1.3 km, URGENT) then Juhu Caterers (~2.1 km). Search is logged.
CALL find_nearest_donors(1, 19.121500, 72.834800, 5, 1);

SELECT '5. Failed search feeds unmet_demand (Jain Thali is listed nowhere)' AS test;
-- Expect: 0 rows from the procedure; Jain Thali failed_searches goes from 4 to 5.
CALL find_nearest_donors(12, 19.121500, 72.834800, 5, NULL);
SELECT * FROM unmet_demand;

SELECT '6. expiring_soon: the donor wastage dashboard' AS test;
-- Expect: Spice Route chicken curry (21:00, URGENT), biryani SR-BI-A (22:00, URGENT), then Juhu batches (23:30, TODAY)
SELECT * FROM expiring_soon;

SELECT '7. update_batch_quantity + audit trigger (reason carried through)' AS test;
-- Expect: newest Batch_Log row = old 18 -> new 15, reason WASTED
CALL update_batch_quantity(1, 5, 'GS-CR-1105', 15, 'WASTED');
SELECT * FROM Batch_Log ORDER BY log_id DESC LIMIT 1;

SELECT '8. Trigger guard: cannot list an already-expired batch' AS test;
-- Expect: ERROR 1644 (45000): Cannot list a batch that is already past its best-before time.
INSERT INTO Food_Batch (donor_id, item_id, batch_no, prepared_at, best_before, quantity, listed_at)
VALUES (1, 5, 'EXP999', '2026-11-04 08:00:00', '2026-11-05 08:00:00', 10, '2026-11-05 20:30:00');

SELECT '9. Trigger guard: best-before beyond the safe shelf life' AS test;
-- Expect: ERROR 1644 (45000): Best-before is longer than the safe shelf life of this food item.
-- (Chicken Curry may be kept 6 hours; this batch claims 10.)
INSERT INTO Food_Batch (donor_id, item_id, batch_no, prepared_at, best_before, quantity, listed_at)
VALUES (4, 3, 'JC-CC-BAD', '2026-11-05 19:00:00', '2026-11-06 05:00:00', 10, '2026-11-05 20:30:00');

SELECT '10. A valid new batch is accepted and auto-logged as LISTED' AS test;
-- Expect: batch inserted; newest Batch_Log row = 0 -> 12, reason LISTED
INSERT INTO Food_Batch (donor_id, item_id, batch_no, prepared_at, best_before, quantity, listed_at)
VALUES (4, 3, 'JC-CC-2', '2026-11-05 19:00:00', '2026-11-06 01:00:00', 12, '2026-11-05 20:30:00');
SELECT * FROM Batch_Log ORDER BY log_id DESC LIMIT 1;

SELECT '11. FEFO reservation: NGO reserves 25 Veg Biryani at Spice Route' AS test;
-- Expect: 20 taken from SR-BI-A (expires 22:00) first, then 5 from SR-BI-B (expires 02:30).
CALL create_reservation(4, 2, @res);
CALL add_reservation_item(@res, 1, 25);
SELECT * FROM Reservation_Batch WHERE reservation_id = @res;
SELECT batch_no, quantity, best_before FROM Food_Batch WHERE donor_id = 2 AND item_id = 1 AND batch_no IN ('SR-BI-A','SR-BI-B');
SELECT * FROM Batch_Log ORDER BY log_id DESC LIMIT 2;

SELECT '12. Hoarding guard: Aarav (individual) already holds 3 units, asks for 4 more' AS test;
-- Expect: ERROR 1644 (45000): Individuals and students can hold at most 6 units at a time; NGOs are exempt.
CALL create_reservation(1, 4, @res2);
CALL add_reservation_item(@res2, 4, 4);

SELECT '13. Not enough stock' AS test;
-- Expect: ERROR 1644 (45000): Not enough unexpired stock to reserve that quantity.
CALL create_reservation(3, 4, @res3);
CALL add_reservation_item(@res3, 2, 999);

SELECT '14. Cannot reserve from a donor that is closed (Fresh Basket opens at 9 PM)' AS test;
-- Expect: ERROR 1644 (45000): This donor is not verified or its pickup window is closed right now.
CALL create_reservation(3, 7, @res4);

SELECT '15. Reservation 5 (Aarav, 8:10 PM) runs out its 45-minute hold at 8:55 PM' AS test;
-- Move the clock to 9:30 PM. Expect: reservations_released = 4 (reservation 5, the NGO's 25-biryani
-- hold from test 11, and the two empty holds left behind by the failed tests 12 and 13).
-- Dal Tadka batch SR-DT-A goes 22 -> 25, and the biryani batches get their units back
-- (SR-BI-A 0 -> 20, SR-BI-B 10 -> 15); each return is logged as RELEASED.
-- (Exp 10 shows how a transaction stops those empty holds from being left behind.)
SET @demo_now = '2026-11-05 21:30:00';
SELECT batch_no, quantity FROM Food_Batch WHERE donor_id = 2 AND item_id = 4 AND batch_no = 'SR-DT-A';
CALL release_expired_reservations();
SELECT batch_no, quantity FROM Food_Batch WHERE donor_id = 2 AND item_id = 4 AND batch_no = 'SR-DT-A';
SELECT * FROM Batch_Log WHERE reason = 'RELEASED' ORDER BY log_id DESC LIMIT 4;
SELECT reservation_id, status FROM Reservation WHERE reservation_id IN (5, @res, @res2, @res3);
SET @demo_now = '2026-11-05 20:30:00';

SELECT '16. Closed reservations cannot be reopened' AS test;
-- Expect: ERROR 1644 (45000): A closed reservation cannot change status.
UPDATE Reservation SET status = 'ACTIVE' WHERE reservation_id = 1;

SELECT '17. Only collected reservations can be rated' AS test;
-- Expect: ERROR 1644 (45000): Only a collected reservation can be rated.
INSERT INTO Feedback (reservation_id, rating, comment) VALUES (3, 1, 'never got it');

SELECT '18. collect_reservation then rate it' AS test;
-- Expect: a fresh reservation is collected, then its feedback row is accepted.
CALL create_reservation(2, 3, @res5);
CALL add_reservation_item(@res5, 6, 2);
CALL collect_reservation(@res5);
INSERT INTO Feedback (reservation_id, rating, comment) VALUES (@res5, 5, 'Fresh bread, thank you');
SELECT r.reservation_id, r.status, f.rating, f.comment
FROM Reservation r JOIN Feedback f ON f.reservation_id = r.reservation_id
WHERE r.reservation_id = @res5;

SELECT '19. cancel_reservation returns stock to the same batch' AS test;
-- Expect: Bread MB-BR-1 shows 15 after reserving 5, then 20 after the cancel (22 originally,
-- minus the 2 loaves collected in test 18).
CALL create_reservation(3, 3, @res6);
CALL add_reservation_item(@res6, 6, 5);
SELECT quantity AS bread_after_reserving FROM Food_Batch WHERE donor_id = 3 AND item_id = 6 AND batch_no = 'MB-BR-1';
CALL cancel_reservation(@res6);
SELECT quantity AS bread_after_cancel FROM Food_Batch WHERE donor_id = 3 AND item_id = 6 AND batch_no = 'MB-BR-1';
SELECT reservation_id, status FROM Reservation WHERE reservation_id = @res6;
