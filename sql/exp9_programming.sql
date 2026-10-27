-- =====================================================================
-- Surplus Food Rescue | DBMS Mini Project | Exp 9 (Phase III)
-- Advanced database programming: 4 functions, 4 views, 6 triggers, 8 procedures.
-- Run exp7_schema_and_data.sql first. Target: MySQL 8.0.16 or later.
--
-- DEMO CLOCK: every object reads the time through fn_now(), which returns
-- @demo_now if you set it, otherwise the real NOW(). Set it once per session:
--     SET @demo_now = '2026-11-05 20:30:00';
-- so results match the sample data and stay reproducible for screenshots.
-- =====================================================================
USE food_rescue;

DELIMITER $$

-- =====================================================================
-- A. STORED FUNCTIONS
-- =====================================================================

-- A1 fn_now(): the single clock for the whole system.
-- Business rule: "now" is defined in one place, so a demo can freeze time.
DROP FUNCTION IF EXISTS fn_now$$
CREATE FUNCTION fn_now() RETURNS DATETIME
NOT DETERMINISTIC
NO SQL
BEGIN
    RETURN COALESCE(@demo_now, NOW());
END$$

-- A2 fn_final_price(): price after a flash discount, but only while that discount is valid.
-- Business rule: an expired discount must never apply.
DROP FUNCTION IF EXISTS fn_final_price$$
CREATE FUNCTION fn_final_price(
    p_price      DECIMAL(8,2),
    p_discount   DECIMAL(5,2),
    p_valid_till DATETIME
) RETURNS DECIMAL(8,2)
NOT DETERMINISTIC               -- depends on the clock
NO SQL
BEGIN
    RETURN ROUND(
        CASE
            WHEN p_discount > 0
             AND (p_valid_till IS NULL OR p_valid_till >= fn_now())
            THEN p_price * (1 - p_discount / 100)
            ELSE p_price
        END, 2);
END$$

-- A3 fn_available_units(): the single definition of "in stock".
-- Business rule: batches past their best-before time are never given out,
-- so they never count. Every view and procedure below reuses this.
DROP FUNCTION IF EXISTS fn_available_units$$
CREATE FUNCTION fn_available_units(
    p_donor_id INT,
    p_item_id  INT
) RETURNS INT
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_units INT;
    SELECT COALESCE(SUM(quantity), 0) INTO v_units
    FROM Food_Batch
    WHERE donor_id = p_donor_id
      AND item_id  = p_item_id
      AND best_before > fn_now();          -- strictly in the future = not expired
    RETURN v_units;
END$$

-- A4 fn_urgency(): turns a best-before time into a label people understand.
-- Business rule: food expiring within 2 hours must be flagged URGENT.
DROP FUNCTION IF EXISTS fn_urgency$$
CREATE FUNCTION fn_urgency(p_best_before DATETIME) RETURNS VARCHAR(10)
NOT DETERMINISTIC
NO SQL
BEGIN
    RETURN CASE
        WHEN p_best_before <= fn_now()                         THEN 'EXPIRED'
        WHEN p_best_before <= fn_now() + INTERVAL 2 HOUR       THEN 'URGENT'
        WHEN DATE(p_best_before) = DATE(fn_now())              THEN 'TODAY'
        ELSE 'LATER'
    END;
END$$

-- =====================================================================
-- B. VIEWS
-- =====================================================================
DELIMITER ;

-- B1 public_listing: the receiver's-eye view.
-- (a) only VERIFIED donors are ever searchable; (b) receivers see price, availability
-- and allergens but never batch numbers, quantities or best-before times.
CREATE OR REPLACE VIEW public_listing AS
SELECT
    d.donor_id,
    d.name AS donor_name,
    d.donor_type,
    d.area,
    fi.item_id,
    fi.item_name,
    fi.category,
    fi.diet_type,
    fi.unit,
    fn_final_price(l.price_per_unit, l.discount_percent, l.discount_valid_till) AS price_per_unit,
    CASE WHEN fn_available_units(d.donor_id, fi.item_id) > 0
         THEN 'Available' ELSE 'Sold Out' END AS availability,
    COALESCE((SELECT GROUP_CONCAT(a.allergen_name ORDER BY a.allergen_name SEPARATOR ', ')
              FROM Item_Allergen ia
              JOIN Allergen a ON a.allergen_id = ia.allergen_id
              WHERE ia.item_id = fi.item_id), 'None declared') AS allergens
FROM Donor d
JOIN Listing   l  ON l.donor_id = d.donor_id
JOIN Food_Item fi ON fi.item_id = l.item_id
WHERE d.status = 'VERIFIED';

-- B2 donor_open_now: VERIFIED donors whose pickup window is open at this exact moment.
-- The inner join to Donor_Hours enforces "no hours row for a weekday = no pickup that day".
CREATE OR REPLACE VIEW donor_open_now AS
SELECT
    d.donor_id,
    d.name AS donor_name,
    d.area,
    d.phone,
    h.pickup_from,
    h.pickup_to,
    TIMESTAMPDIFF(MINUTE, fn_now(), TIMESTAMP(DATE(fn_now()), h.pickup_to)) AS minutes_left
FROM Donor d
JOIN Donor_Hours h ON h.donor_id = d.donor_id
WHERE d.status = 'VERIFIED'
  AND h.day_of_week = DAYOFWEEK(fn_now())
  AND TIME(fn_now()) BETWEEN h.pickup_from AND h.pickup_to;

-- B3 unmet_demand: items people searched for but found nowhere.
-- Live feed for the "alert donors to local demand" feature.
CREATE OR REPLACE VIEW unmet_demand AS
SELECT
    fi.item_id,
    fi.item_name,
    fi.category,
    COUNT(*)           AS failed_searches,
    MAX(sl.searched_at) AS last_searched
FROM Search_Log sl
JOIN Food_Item fi ON fi.item_id = sl.item_id
WHERE sl.donors_found = 0
GROUP BY fi.item_id, fi.item_name, fi.category
ORDER BY failed_searches DESC;

-- B4 expiring_soon: the donor's wastage dashboard (donor-side, so batches ARE visible).
-- Batches of verified donors that expire within the next 3 hours and still have units.
CREATE OR REPLACE VIEW expiring_soon AS
SELECT
    d.donor_id,
    d.name AS donor_name,
    fi.item_name,
    b.batch_no,
    b.quantity,
    b.best_before,
    TIMESTAMPDIFF(MINUTE, fn_now(), b.best_before) AS minutes_left,
    fn_urgency(b.best_before) AS urgency
FROM Food_Batch b
JOIN Donor     d  ON d.donor_id = b.donor_id
JOIN Food_Item fi ON fi.item_id = b.item_id
WHERE d.status = 'VERIFIED'
  AND b.quantity > 0
  AND b.best_before >  fn_now()
  AND b.best_before <= fn_now() + INTERVAL 3 HOUR
ORDER BY b.best_before;

DELIMITER $$

-- =====================================================================
-- C. TRIGGERS
-- =====================================================================

-- C1 trg_batch_before_insert
-- Business rules: (1) you cannot list a batch that is already past its best-before time;
-- (2) best-before may not exceed the safe shelf life of that food item.
-- SIGNAL aborts the INSERT with a clear error, so unsafe food never reaches the table.
DROP TRIGGER IF EXISTS trg_batch_before_insert$$
CREATE TRIGGER trg_batch_before_insert
BEFORE INSERT ON Food_Batch
FOR EACH ROW
BEGIN
    DECLARE v_max_hours INT;

    IF NEW.best_before <= fn_now() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cannot list a batch that is already past its best-before time.';
    END IF;

    SELECT max_shelf_hours INTO v_max_hours
    FROM Food_Item WHERE item_id = NEW.item_id;

    IF NEW.best_before > NEW.prepared_at + INTERVAL v_max_hours HOUR THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Best-before is longer than the safe shelf life of this food item.';
    END IF;
END$$

-- C2 trg_batch_after_insert
-- Every new batch is auto-logged as LISTED, an audit trail no client code can skip.
DROP TRIGGER IF EXISTS trg_batch_after_insert$$
CREATE TRIGGER trg_batch_after_insert
AFTER INSERT ON Food_Batch
FOR EACH ROW
BEGIN
    INSERT INTO Batch_Log (donor_id, item_id, batch_no, old_qty, new_qty, reason, logged_at)
    VALUES (NEW.donor_id, NEW.item_id, NEW.batch_no, 0, NEW.quantity, 'LISTED', fn_now());
END$$

-- C3 trg_batch_after_update
-- Every change to a batch quantity is audited. The trigger records what changed; the caller
-- sets @batch_change_reason to say why (RESERVED / RELEASED / ADJUSTED / EXPIRED / WASTED),
-- defaulting to ADJUSTED. An invalid reason is rejected by the CHECK on Batch_Log.
DROP TRIGGER IF EXISTS trg_batch_after_update$$
CREATE TRIGGER trg_batch_after_update
AFTER UPDATE ON Food_Batch
FOR EACH ROW
BEGIN
    IF NEW.quantity <> OLD.quantity THEN
        INSERT INTO Batch_Log (donor_id, item_id, batch_no, old_qty, new_qty, reason, logged_at)
        VALUES (NEW.donor_id, NEW.item_id, NEW.batch_no,
                OLD.quantity, NEW.quantity,
                COALESCE(@batch_change_reason, 'ADJUSTED'), fn_now());
    END IF;
END$$

-- C4 trg_ritem_before_insert
-- Business rule: individuals and students may hold at most 6 units at a time across all
-- their active reservations, so food is not hoarded; NGOs are exempt.
DROP TRIGGER IF EXISTS trg_ritem_before_insert$$
CREATE TRIGGER trg_ritem_before_insert
BEFORE INSERT ON Reservation_Item
FOR EACH ROW
BEGIN
    DECLARE v_receiver INT;
    DECLARE v_type     VARCHAR(12);
    DECLARE v_held     INT;

    SELECT r.receiver_id, rc.receiver_type INTO v_receiver, v_type
    FROM Reservation r
    JOIN Receiver rc ON rc.receiver_id = r.receiver_id
    WHERE r.reservation_id = NEW.reservation_id;

    IF v_type <> 'NGO' THEN
        SELECT COALESCE(SUM(ri.quantity), 0) INTO v_held
        FROM Reservation_Item ri
        JOIN Reservation r2 ON r2.reservation_id = ri.reservation_id
        WHERE r2.receiver_id = v_receiver
          AND r2.status = 'ACTIVE';

        IF v_held + NEW.quantity > 6 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Individuals and students can hold at most 6 units at a time; NGOs are exempt.';
        END IF;
    END IF;
END$$

-- C5 trg_reservation_status_guard
-- Business rule: once a reservation is COLLECTED, EXPIRED or CANCELLED it is closed for good.
DROP TRIGGER IF EXISTS trg_reservation_status_guard$$
CREATE TRIGGER trg_reservation_status_guard
BEFORE UPDATE ON Reservation
FOR EACH ROW
BEGIN
    IF OLD.status <> 'ACTIVE' AND NEW.status <> OLD.status THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A closed reservation cannot change status.';
    END IF;
END$$

-- C6 trg_feedback_before_insert
-- Business rule: only a reservation that was actually COLLECTED can be rated.
DROP TRIGGER IF EXISTS trg_feedback_before_insert$$
CREATE TRIGGER trg_feedback_before_insert
BEFORE INSERT ON Feedback
FOR EACH ROW
BEGIN
    DECLARE v_status VARCHAR(10);
    SELECT status INTO v_status FROM Reservation WHERE reservation_id = NEW.reservation_id;
    IF v_status IS NULL OR v_status <> 'COLLECTED' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Only a collected reservation can be rated.';
    END IF;
END$$

-- =====================================================================
-- D. STORED PROCEDURES
-- =====================================================================

-- D1 update_batch_quantity()
-- The only sanctioned way to change stock by hand. It sets the reason, runs the update
-- (which fires the audit trigger with that reason), then clears the reason so it
-- cannot leak into the next, unrelated update.
DROP PROCEDURE IF EXISTS update_batch_quantity$$
CREATE PROCEDURE update_batch_quantity(
    IN p_donor_id INT,
    IN p_item_id  INT,
    IN p_batch_no VARCHAR(20),
    IN p_new_qty  INT,
    IN p_reason   VARCHAR(20)
)
BEGIN
    SET @batch_change_reason = p_reason;
    UPDATE Food_Batch
    SET quantity = p_new_qty
    WHERE donor_id = p_donor_id
      AND item_id  = p_item_id
      AND batch_no = p_batch_no;
    SET @batch_change_reason = NULL;          -- reset so it doesn't bleed over
END$$

-- D2 find_nearest_donors()
-- The core receiver feature: VERIFIED donors whose pickup window is open now (with at
-- least 30 minutes left to reach them), who have the item in unexpired stock, within a
-- radius, nearest first (ST_Distance_Sphere takes POINT(longitude, latitude), returns metres).
-- Side effect: logs every search, which feeds unmet_demand when nothing is found.
-- p_receiver_id may be NULL for a guest.
DROP PROCEDURE IF EXISTS find_nearest_donors$$
CREATE PROCEDURE find_nearest_donors(
    IN p_item_id     INT,
    IN p_lat         DECIMAL(9,6),
    IN p_long        DECIMAL(9,6),
    IN p_radius_km   DECIMAL(6,2),
    IN p_receiver_id INT
)
BEGIN
    DECLARE v_found INT DEFAULT 0;

    -- 1) count the matches, for the search log
    SELECT COUNT(*) INTO v_found
    FROM Donor d
    JOIN Listing l ON l.donor_id = d.donor_id AND l.item_id = p_item_id
    WHERE d.status = 'VERIFIED'
      AND fn_available_units(d.donor_id, p_item_id) > 0
      AND EXISTS (SELECT 1 FROM Donor_Hours h
                  WHERE h.donor_id = d.donor_id
                    AND h.day_of_week = DAYOFWEEK(fn_now())
                    AND TIME(fn_now()) BETWEEN h.pickup_from AND SUBTIME(h.pickup_to, '00:30:00'))
      AND ST_Distance_Sphere(POINT(d.longitude, d.latitude), POINT(p_long, p_lat)) / 1000 <= p_radius_km;

    -- 2) record the search (receiver_id NULL = guest)
    INSERT INTO Search_Log (receiver_id, item_id, latitude, longitude, searched_at, donors_found)
    VALUES (p_receiver_id, p_item_id, p_lat, p_long, fn_now(), v_found);

    -- 3) return the ranked results
    SELECT
        d.donor_id,
        d.name AS donor_name,
        d.area,
        d.phone,
        fn_final_price(l.price_per_unit, l.discount_percent, l.discount_valid_till) AS price_per_unit,
        ROUND(ST_Distance_Sphere(POINT(d.longitude, d.latitude), POINT(p_long, p_lat)) / 1000, 2) AS distance_km,
        -- FEFO: you are handed the batch that expires first, so show how fresh THAT one is
        fn_urgency((SELECT MIN(b.best_before) FROM Food_Batch b
                    WHERE b.donor_id = d.donor_id AND b.item_id = p_item_id
                      AND b.quantity > 0 AND b.best_before > fn_now())) AS freshness
    FROM Donor d
    JOIN Listing l ON l.donor_id = d.donor_id AND l.item_id = p_item_id
    WHERE d.status = 'VERIFIED'
      AND fn_available_units(d.donor_id, p_item_id) > 0
      AND EXISTS (SELECT 1 FROM Donor_Hours h
                  WHERE h.donor_id = d.donor_id
                    AND h.day_of_week = DAYOFWEEK(fn_now())
                    AND TIME(fn_now()) BETWEEN h.pickup_from AND SUBTIME(h.pickup_to, '00:30:00'))
      AND ST_Distance_Sphere(POINT(d.longitude, d.latitude), POINT(p_long, p_lat)) / 1000 <= p_radius_km
    ORDER BY distance_km ASC, donor_name ASC;
END$$

-- D3 create_reservation()
-- Opens an empty 45-minute hold at one donor. Business rules: the donor must be VERIFIED
-- and its pickup window must be open right now.
DROP PROCEDURE IF EXISTS create_reservation$$
CREATE PROCEDURE create_reservation(
    IN  p_receiver_id INT,
    IN  p_donor_id    INT,
    OUT p_reservation_id INT
)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM donor_open_now WHERE donor_id = p_donor_id) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'This donor is not verified or its pickup window is closed right now.';
    END IF;

    INSERT INTO Reservation (receiver_id, donor_id, status, reserved_at)
    VALUES (p_receiver_id, p_donor_id, 'ACTIVE', fn_now());

    SET p_reservation_id = LAST_INSERT_ID();
END$$

-- D4 add_reservation_item()
-- Adds one item to an ACTIVE reservation and takes the units FEFO (first expiry, first out):
-- earliest best-before batch first, spilling into the next batch if needed. Saves the price
-- at that moment and records which batch each unit came from. Raises an error (so the
-- caller's transaction can ROLLBACK) if stock is short. It is meant to run INSIDE a
-- transaction (see reserve_basket in Exp 10), so a failure never leaves half a hold behind.
DROP PROCEDURE IF EXISTS add_reservation_item$$
CREATE PROCEDURE add_reservation_item(
    IN p_reservation_id INT,
    IN p_item_id        INT,
    IN p_qty            INT
)
BEGIN
    DECLARE v_donor  INT;
    DECLARE v_status VARCHAR(10);
    DECLARE v_price  DECIMAL(8,2);
    DECLARE v_avail  INT;
    DECLARE v_need   INT;
    DECLARE v_batch  VARCHAR(20);
    DECLARE v_bqty   INT;
    DECLARE v_take   INT;

    SELECT donor_id, status INTO v_donor, v_status
    FROM Reservation WHERE reservation_id = p_reservation_id FOR UPDATE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reservation not found.';
    END IF;
    IF v_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Items can only be added to an ACTIVE reservation.';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be greater than zero.';
    END IF;
    -- Lock this item's unexpired batches first, THEN count them. Two receivers racing for the
    -- last portions therefore queue up: the second one waits, re-counts the true remainder and
    -- is refused cleanly instead of being promised food that is already held.
    SELECT COALESCE(SUM(quantity), 0) INTO v_avail
    FROM Food_Batch
    WHERE donor_id = v_donor AND item_id = p_item_id AND best_before > fn_now()
    FOR UPDATE;
    IF v_avail < p_qty THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Not enough unexpired stock to reserve that quantity.';
    END IF;

    -- price snapshot (Business rule: later price changes never affect a held order)
    SELECT fn_final_price(price_per_unit, discount_percent, discount_valid_till) INTO v_price
    FROM Listing WHERE donor_id = v_donor AND item_id = p_item_id;

    INSERT INTO Reservation_Item (reservation_id, item_id, quantity, price_at_reservation)
    VALUES (p_reservation_id, p_item_id, p_qty, v_price);

    -- FEFO allocation
    SET v_need = p_qty;
    SET @batch_change_reason = 'RESERVED';
    WHILE v_need > 0 DO
        SET v_batch = NULL;
        SET v_bqty  = NULL;
        SELECT batch_no, quantity INTO v_batch, v_bqty
        FROM Food_Batch
        WHERE donor_id = v_donor AND item_id = p_item_id
          AND quantity > 0 AND best_before > fn_now()
        ORDER BY best_before, batch_no
        LIMIT 1
        FOR UPDATE;

        IF v_batch IS NULL THEN
            SET @batch_change_reason = NULL;
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock ran out while reserving.';
        END IF;

        SET v_take = LEAST(v_need, v_bqty);
        UPDATE Food_Batch SET quantity = quantity - v_take
        WHERE donor_id = v_donor AND item_id = p_item_id AND batch_no = v_batch;

        INSERT INTO Reservation_Batch (reservation_id, item_id, donor_id, batch_no, quantity)
        VALUES (p_reservation_id, p_item_id, v_donor, v_batch, v_take);

        SET v_need = v_need - v_take;
    END WHILE;
    SET @batch_change_reason = NULL;
END$$

-- D5 release_reservation()
-- Closes a reservation as EXPIRED or CANCELLED and returns every held unit to the exact
-- batch it came from (logged as RELEASED). Does nothing unless the reservation is ACTIVE.
DROP PROCEDURE IF EXISTS release_reservation$$
CREATE PROCEDURE release_reservation(
    IN p_reservation_id INT,
    IN p_new_status     VARCHAR(10)
)
BEGIN
    DECLARE v_done   INT DEFAULT 0;
    DECLARE v_status VARCHAR(10);
    DECLARE v_donor  INT;
    DECLARE v_item   INT;
    DECLARE v_batch  VARCHAR(20);
    DECLARE v_qty    INT;
    DECLARE cur CURSOR FOR
        SELECT donor_id, item_id, batch_no, quantity
        FROM Reservation_Batch WHERE reservation_id = p_reservation_id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    IF p_new_status NOT IN ('EXPIRED','CANCELLED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reservation can only be released as EXPIRED or CANCELLED.';
    END IF;

    SELECT status INTO v_status FROM Reservation WHERE reservation_id = p_reservation_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reservation not found.';
    END IF;

    IF v_status = 'ACTIVE' THEN
        SET @batch_change_reason = 'RELEASED';
        OPEN cur;
        read_loop: LOOP
            FETCH cur INTO v_donor, v_item, v_batch, v_qty;
            IF v_done = 1 THEN LEAVE read_loop; END IF;
            UPDATE Food_Batch SET quantity = quantity + v_qty
            WHERE donor_id = v_donor AND item_id = v_item AND batch_no = v_batch;
        END LOOP;
        CLOSE cur;
        SET @batch_change_reason = NULL;

        UPDATE Reservation SET status = p_new_status WHERE reservation_id = p_reservation_id;
    END IF;
END$$

-- D6 release_expired_reservations()
-- The 45-minute rule: every ACTIVE reservation older than 45 minutes is released back
-- to stock. Meant to run on a schedule; returns how many it released.
DROP PROCEDURE IF EXISTS release_expired_reservations$$
CREATE PROCEDURE release_expired_reservations()
BEGIN
    DECLARE v_id    INT;
    DECLARE v_count INT DEFAULT 0;

    expire_loop: LOOP
        SET v_id = NULL;
        SELECT reservation_id INTO v_id
        FROM Reservation
        WHERE status = 'ACTIVE'
          AND reserved_at + INTERVAL 45 MINUTE <= fn_now()
        ORDER BY reservation_id
        LIMIT 1;

        IF v_id IS NULL THEN LEAVE expire_loop; END IF;
        CALL release_reservation(v_id, 'EXPIRED');
        SET v_count = v_count + 1;
    END LOOP;

    SELECT v_count AS reservations_released;
END$$

-- D7 collect_reservation()
-- Donor marks a reservation as collected. Business rule: only an ACTIVE reservation whose
-- 45-minute hold has not run out can be collected.
DROP PROCEDURE IF EXISTS collect_reservation$$
CREATE PROCEDURE collect_reservation(IN p_reservation_id INT)
BEGIN
    DECLARE v_status VARCHAR(10);
    DECLARE v_at     DATETIME;

    SELECT status, reserved_at INTO v_status, v_at
    FROM Reservation WHERE reservation_id = p_reservation_id FOR UPDATE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Reservation not found.';
    END IF;
    IF v_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an ACTIVE reservation can be collected.';
    END IF;
    IF v_at + INTERVAL 45 MINUTE <= fn_now() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'The 45-minute hold has expired.';
    END IF;

    UPDATE Reservation SET status = 'COLLECTED' WHERE reservation_id = p_reservation_id;
END$$

-- D8 cancel_reservation()
-- Receiver gives the food back early; units return to the batches they came from.
DROP PROCEDURE IF EXISTS cancel_reservation$$
CREATE PROCEDURE cancel_reservation(IN p_reservation_id INT)
BEGIN
    CALL release_reservation(p_reservation_id, 'CANCELLED');
END$$

DELIMITER ;
