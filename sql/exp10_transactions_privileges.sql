-- =====================================================================
-- Surplus Food Rescue | DBMS Mini Project | Exp 10 (Phase IV)
-- Transactions (all-or-nothing reservations), locking, and role-based user privileges.
-- Run exp7 and exp9_programming first, as a user with admin rights (root).
-- Run:  mysql -u root -p -t --force < exp10_transactions_privileges.sql
-- =====================================================================
USE food_rescue;
SET @demo_now = '2026-11-05 20:30:00';      -- Thursday 8:30 PM, same demo clock as before

-- =====================================================================
-- A. TRANSACTIONS: every item in a reservation is held, or none is
-- =====================================================================

DELIMITER $$

-- A0 reserve_basket(): the whole reservation as ONE atomic unit.
-- Opens the hold, adds up to three items (FEFO), and COMMITs. If anything fails
-- (donor closed, stock short, 6-unit cap, ...) the handler ROLLS BACK everything, so no
-- half-made reservation and no stock stays locked, then re-raises the original error.
DROP PROCEDURE IF EXISTS reserve_basket$$
CREATE PROCEDURE reserve_basket(
    IN p_receiver_id INT,
    IN p_donor_id    INT,
    IN p_item1 INT, IN p_qty1 INT,
    IN p_item2 INT, IN p_qty2 INT,
    IN p_item3 INT, IN p_qty3 INT
)
BEGIN
    DECLARE v_res INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @batch_change_reason = NULL;
        RESIGNAL;
    END;

    START TRANSACTION;
    CALL create_reservation(p_receiver_id, p_donor_id, v_res);
    CALL add_reservation_item(v_res, p_item1, p_qty1);
    IF p_item2 IS NOT NULL THEN CALL add_reservation_item(v_res, p_item2, p_qty2); END IF;
    IF p_item3 IS NOT NULL THEN CALL add_reservation_item(v_res, p_item3, p_qty3); END IF;
    COMMIT;

    SELECT v_res AS reservation_id, 'COMMITTED' AS outcome;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- A1 COMMIT: an NGO reserves 10 biryani + 5 dal + 4 fruit salad at Juhu Caterers.
-- Expect: all three items held; stock drops by exactly those amounts.
-- ---------------------------------------------------------------------
SELECT 'A1. COMMIT - three items reserved together' AS test;
SELECT item_id, SUM(quantity) AS units_before
FROM Food_Batch WHERE donor_id = 4 AND item_id IN (1, 4, 9) AND best_before > @demo_now
GROUP BY item_id;

START TRANSACTION;
CALL create_reservation(3, 4, @r1);
CALL add_reservation_item(@r1, 1, 10);
CALL add_reservation_item(@r1, 4, 5);
CALL add_reservation_item(@r1, 9, 4);
COMMIT;

SELECT ri.reservation_id, fi.item_name, ri.quantity, ri.price_at_reservation
FROM Reservation_Item ri JOIN Food_Item fi ON fi.item_id = ri.item_id
WHERE ri.reservation_id = @r1;
SELECT item_id, SUM(quantity) AS units_after
FROM Food_Batch WHERE donor_id = 4 AND item_id IN (1, 4, 9) AND best_before > @demo_now
GROUP BY item_id;

-- ---------------------------------------------------------------------
-- A2 ROLLBACK: the second item cannot be filled (999 dal), so the first must be undone too.
-- Expect: ERROR 1644 on the second item; after ROLLBACK there is NO new reservation and the
-- stock is exactly as before.
-- ---------------------------------------------------------------------
SELECT 'A2. ROLLBACK - second item fails, first is undone' AS test;
SELECT COUNT(*) AS reservations_before FROM Reservation;
SELECT SUM(quantity) AS biryani_units_before
FROM Food_Batch WHERE donor_id = 4 AND item_id = 1 AND best_before > @demo_now;

START TRANSACTION;
CALL create_reservation(4, 4, @r2);
CALL add_reservation_item(@r2, 1, 5);          -- succeeds inside the transaction
CALL add_reservation_item(@r2, 4, 999);        -- ERROR: not enough stock
ROLLBACK;                                      -- undo the hold AND the 5 biryani

SELECT COUNT(*) AS reservations_after FROM Reservation;
SELECT SUM(quantity) AS biryani_units_after
FROM Food_Batch WHERE donor_id = 4 AND item_id = 1 AND best_before > @demo_now;

-- ---------------------------------------------------------------------
-- A3 The same all-or-nothing guarantee, packaged as one procedure call.
-- ---------------------------------------------------------------------
SELECT 'A3a. reserve_basket succeeds' AS test;
-- Expect: reservation_id and outcome COMMITTED
CALL reserve_basket(3, 2, 2, 4, 4, 6, NULL, NULL);

SELECT 'A3b. reserve_basket fails and leaves nothing behind' AS test;
-- Expect: ERROR 1644 (Not enough unexpired stock...), and the counts below do not change.
SELECT COUNT(*) AS reservations_before, (SELECT SUM(quantity) FROM Food_Batch WHERE donor_id = 2 AND item_id = 1) AS biryani_before FROM Reservation;
CALL reserve_basket(3, 2, 1, 5, 4, 999, NULL, NULL);
SELECT COUNT(*) AS reservations_after,  (SELECT SUM(quantity) FROM Food_Batch WHERE donor_id = 2 AND item_id = 1) AS biryani_after  FROM Reservation;

SELECT 'A3c. reserve_basket respects the 6-unit cap for individuals' AS test;
-- Expect: ERROR 1644 (Individuals and students can hold at most 6 units...), nothing left behind.
CALL reserve_basket(5, 4, 1, 4, 4, 3, NULL, NULL);

-- =====================================================================
-- B. LOCKING AND CONCURRENCY (needs TWO terminals; steps are shown as comments)
-- =====================================================================
-- Two receivers must never be handed the same last portions. add_reservation_item takes the
-- batch row with SELECT ... FOR UPDATE, so the second session waits for the first.
--
--   Terminal 1                                         Terminal 2
--   ----------                                         ----------
--   USE food_rescue;                                   USE food_rescue;
--   SET @demo_now='2026-11-05 20:30:00';               SET @demo_now='2026-11-05 20:30:00';
--   START TRANSACTION;                                 START TRANSACTION;
--   CALL create_reservation(3, 4, @a);
--   CALL add_reservation_item(@a, 2, 30);
--     -- 30 of Juhu's 35 paneer are now held
--                                                      CALL create_reservation(4, 4, @b);
--                                                      CALL add_reservation_item(@b, 2, 30);
--                                                        -- this call WAITS: Terminal 1 has the
--                                                        -- paneer batch locked.
--   COMMIT;
--                                                        -- Terminal 2 now wakes up, re-counts the
--                                                        -- true remainder (5) and is refused with
--                                                        -- "Not enough unexpired stock".
--                                                      ROLLBACK;
--   (If Terminal 1 had issued ROLLBACK instead, Terminal 2 would have got its 30.)
--
-- To SEE a lock wait instead, in Terminal 1 run:
--   START TRANSACTION;
--   SELECT * FROM Food_Batch WHERE donor_id = 4 AND item_id = 2 FOR UPDATE;
-- and in Terminal 2 run CALL add_reservation_item(...) on paneer: it hangs until Terminal 1
-- issues COMMIT/ROLLBACK (or fails with "Lock wait timeout exceeded" after 50 seconds).

-- =====================================================================
-- C. USER PRIVILEGES: each role sees and does only what it needs
-- =====================================================================
-- Three accounts. Passwords here are for the demo only.
DROP USER IF EXISTS 'fr_admin'@'localhost';
DROP USER IF EXISTS 'fr_donor'@'localhost';
DROP USER IF EXISTS 'fr_receiver'@'localhost';

CREATE USER 'fr_admin'@'localhost'    IDENTIFIED BY 'Admin@123';
CREATE USER 'fr_donor'@'localhost'    IDENTIFIED BY 'Donor@123';
CREATE USER 'fr_receiver'@'localhost' IDENTIFIED BY 'Receiver@123';

-- RECEIVER: reads only the safe public views; everything else goes through procedures.
-- It can never read Food_Batch (stock hidden), Reservation_Batch, Batch_Log or other receivers.
GRANT SELECT  ON food_rescue.public_listing TO 'fr_receiver'@'localhost';
GRANT SELECT  ON food_rescue.donor_open_now TO 'fr_receiver'@'localhost';
GRANT EXECUTE ON PROCEDURE food_rescue.find_nearest_donors   TO 'fr_receiver'@'localhost';
GRANT EXECUTE ON PROCEDURE food_rescue.reserve_basket        TO 'fr_receiver'@'localhost';
GRANT EXECUTE ON PROCEDURE food_rescue.cancel_reservation    TO 'fr_receiver'@'localhost';

-- DONOR: manages its own listings and stock; cannot touch other tables or verify itself.
GRANT SELECT, INSERT, UPDATE ON food_rescue.Listing      TO 'fr_donor'@'localhost';   -- no DELETE
GRANT INSERT                 ON food_rescue.Food_Batch   TO 'fr_donor'@'localhost';   -- receive stock
GRANT SELECT ON food_rescue.public_listing TO 'fr_donor'@'localhost';
GRANT SELECT ON food_rescue.expiring_soon  TO 'fr_donor'@'localhost';
GRANT SELECT ON food_rescue.unmet_demand   TO 'fr_donor'@'localhost';
GRANT EXECUTE ON PROCEDURE food_rescue.update_batch_quantity TO 'fr_donor'@'localhost';
GRANT EXECUTE ON PROCEDURE food_rescue.collect_reservation   TO 'fr_donor'@'localhost';

-- ADMIN: reads everything, and may change ONLY the three verification columns of Donor.
GRANT SELECT ON food_rescue.* TO 'fr_admin'@'localhost';
GRANT UPDATE (status, verified_by, verified_at) ON food_rescue.Donor TO 'fr_admin'@'localhost';
GRANT EXECUTE ON PROCEDURE food_rescue.release_expired_reservations TO 'fr_admin'@'localhost';

FLUSH PRIVILEGES;

SELECT 'C. Privileges granted' AS test;
SHOW GRANTS FOR 'fr_receiver'@'localhost';
SHOW GRANTS FOR 'fr_donor'@'localhost';
SHOW GRANTS FOR 'fr_admin'@'localhost';

-- Now prove it: log in as each role and run its test script (see README):
--   mysql -u fr_receiver -pReceiver@123 -t --force < exp10_role_tests/test_as_receiver.sql
--   mysql -u fr_donor    -pDonor@123    -t --force < exp10_role_tests/test_as_donor.sql
--   mysql -u fr_admin    -pAdmin@123    -t --force < exp10_role_tests/test_as_admin.sql
