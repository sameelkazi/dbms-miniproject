-- =====================================================================
-- Surplus Food Rescue | DBMS Mini Project | Exp 7 (Phase I)
-- Tables + sample data. Run this file first, then exp8, exp9, exp10.
-- Target: MySQL 8.0.16 or later (CHECK constraints are enforced from 8.0.16).
-- =====================================================================
DROP DATABASE IF EXISTS food_rescue;
CREATE DATABASE food_rescue;
USE food_rescue;

-- ---------------------------------------------------------------------
-- 1. Admin: staff who review donor registrations
-- ---------------------------------------------------------------------
CREATE TABLE Admin (
    admin_id INT AUTO_INCREMENT PRIMARY KEY,
    name     VARCHAR(60)  NOT NULL,
    email    VARCHAR(100) NOT NULL UNIQUE,
    phone    VARCHAR(15)
);

-- ---------------------------------------------------------------------
-- 2. Donor: restaurants, bakeries, caterers, canteens and shops that give
--    away surplus food. Only VERIFIED donors appear in search.
--    verified_by = the admin who reviewed it (verified OR rejected).
-- ---------------------------------------------------------------------
CREATE TABLE Donor (
    donor_id    INT AUTO_INCREMENT PRIMARY KEY,
    fssai_no    VARCHAR(14)  NOT NULL UNIQUE,          -- 14-digit FSSAI licence
    name        VARCHAR(100) NOT NULL,
    donor_type  VARCHAR(15)  NOT NULL,
    address     VARCHAR(200) NOT NULL,
    area        VARCHAR(60)  NOT NULL,
    pincode     CHAR(6)      NOT NULL,
    latitude    DECIMAL(9,6) NOT NULL,
    longitude   DECIMAL(9,6) NOT NULL,
    phone       VARCHAR(15)  NOT NULL,
    status      VARCHAR(10)  NOT NULL DEFAULT 'PENDING',
    verified_by INT,
    verified_at DATETIME,
    CONSTRAINT chk_donor_type     CHECK (donor_type IN ('RESTAURANT','BAKERY','CATERER','CANTEEN','SUPERMARKET')),
    CONSTRAINT chk_donor_status   CHECK (status IN ('PENDING','VERIFIED','REJECTED')),
    CONSTRAINT chk_donor_reviewed CHECK (status = 'PENDING' OR verified_by IS NOT NULL),
    CONSTRAINT chk_donor_lat      CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT chk_donor_lng      CHECK (longitude BETWEEN -180 AND 180),
    CONSTRAINT fk_donor_admin FOREIGN KEY (verified_by) REFERENCES Admin(admin_id)
    -- No ON DELETE action: MySQL forbids referential actions on a column used in a CHECK.
);

-- ---------------------------------------------------------------------
-- 3. Donor_Hours (weak entity): the PICKUP WINDOW for each weekday.
--    day_of_week follows MySQL's DAYOFWEEK(): 1 = Sunday ... 7 = Saturday.
--    No row for a day = no pickup that day.
-- ---------------------------------------------------------------------
CREATE TABLE Donor_Hours (
    donor_id    INT     NOT NULL,
    day_of_week TINYINT NOT NULL,
    pickup_from TIME    NOT NULL,
    pickup_to   TIME    NOT NULL,
    PRIMARY KEY (donor_id, day_of_week),
    CONSTRAINT chk_hours_day   CHECK (day_of_week BETWEEN 1 AND 7),
    CONSTRAINT chk_hours_order CHECK (pickup_to > pickup_from),
    CONSTRAINT fk_hours_donor FOREIGN KEY (donor_id) REFERENCES Donor(donor_id)
        ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 4. Food_Item: master catalogue. unit = smallest unit that is priced and counted.
--    max_shelf_hours = longest safe time between preparation and best-before.
-- ---------------------------------------------------------------------
CREATE TABLE Food_Item (
    item_id               INT AUTO_INCREMENT PRIMARY KEY,
    item_name             VARCHAR(80) NOT NULL UNIQUE,
    category              VARCHAR(15) NOT NULL,
    diet_type             VARCHAR(8)  NOT NULL,
    unit                  VARCHAR(10) NOT NULL,
    max_shelf_hours       INT         NOT NULL,
    requires_refrigeration BOOLEAN    NOT NULL DEFAULT FALSE,
    CONSTRAINT chk_item_category CHECK (category IN ('COOKED','BAKERY','DAIRY','FRUIT_VEG','BEVERAGE','PACKAGED')),
    CONSTRAINT chk_item_diet     CHECK (diet_type IN ('VEG','NONVEG','VEGAN')),
    CONSTRAINT chk_item_unit     CHECK (unit IN ('portion','piece','packet','kg','litre')),
    CONSTRAINT chk_item_shelf    CHECK (max_shelf_hours > 0)
);

-- ---------------------------------------------------------------------
-- 5. Allergen master list
-- ---------------------------------------------------------------------
CREATE TABLE Allergen (
    allergen_id   INT AUTO_INCREMENT PRIMARY KEY,
    allergen_name VARCHAR(30) NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------
-- 6. Item_Allergen: resolves Food_Item M:N Allergen ("contains")
-- ---------------------------------------------------------------------
CREATE TABLE Item_Allergen (
    item_id     INT NOT NULL,
    allergen_id INT NOT NULL,
    PRIMARY KEY (item_id, allergen_id),
    CONSTRAINT fk_ia_item     FOREIGN KEY (item_id)     REFERENCES Food_Item(item_id) ON DELETE CASCADE,
    CONSTRAINT fk_ia_allergen FOREIGN KEY (allergen_id) REFERENCES Allergen(allergen_id)
);

-- ---------------------------------------------------------------------
-- 7. Listing (associative entity): one item offered by one donor + its price.
--    price_per_unit = rescue price (0 = free). The final price is NOT stored.
--    discount_valid_till = end of an extra flash discount; NULL = no end.
-- ---------------------------------------------------------------------
CREATE TABLE Listing (
    donor_id            INT NOT NULL,
    item_id             INT NOT NULL,
    price_per_unit      DECIMAL(8,2) NOT NULL,
    discount_percent    DECIMAL(5,2) NOT NULL DEFAULT 0,
    discount_valid_till DATETIME,
    PRIMARY KEY (donor_id, item_id),
    CONSTRAINT chk_listing_price    CHECK (price_per_unit >= 0),
    CONSTRAINT chk_listing_discount CHECK (discount_percent BETWEEN 0 AND 100),
    CONSTRAINT fk_listing_donor FOREIGN KEY (donor_id) REFERENCES Donor(donor_id) ON DELETE CASCADE,
    CONSTRAINT fk_listing_item  FOREIGN KEY (item_id)  REFERENCES Food_Item(item_id)
);

-- ---------------------------------------------------------------------
-- 8. Food_Batch (weak entity under Listing): hidden from receivers.
--    best_before is a DATETIME because food expires in hours, not days.
-- ---------------------------------------------------------------------
CREATE TABLE Food_Batch (
    donor_id    INT         NOT NULL,
    item_id     INT         NOT NULL,
    batch_no    VARCHAR(20) NOT NULL,
    prepared_at DATETIME    NOT NULL,
    best_before DATETIME    NOT NULL,
    quantity    INT         NOT NULL,
    listed_at   DATETIME    NOT NULL,
    PRIMARY KEY (donor_id, item_id, batch_no),
    CONSTRAINT chk_batch_qty    CHECK (quantity >= 0),
    CONSTRAINT chk_batch_expiry CHECK (best_before > prepared_at),
    CONSTRAINT fk_batch_listing FOREIGN KEY (donor_id, item_id) REFERENCES Listing(donor_id, item_id)
        ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 9. Batch_Log: audit trail of every quantity change.
--    No cascade: a batch that has history can't be deleted; set its qty to 0.
-- ---------------------------------------------------------------------
CREATE TABLE Batch_Log (
    log_id    INT AUTO_INCREMENT PRIMARY KEY,
    donor_id  INT         NOT NULL,
    item_id   INT         NOT NULL,
    batch_no  VARCHAR(20) NOT NULL,
    old_qty   INT         NOT NULL,
    new_qty   INT         NOT NULL,
    reason    VARCHAR(20) NOT NULL,
    logged_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_log_reason CHECK (reason IN ('LISTED','RESERVED','RELEASED','ADJUSTED','EXPIRED','WASTED')),
    CONSTRAINT fk_log_batch FOREIGN KEY (donor_id, item_id, batch_no)
        REFERENCES Food_Batch(donor_id, item_id, batch_no)
);

-- ---------------------------------------------------------------------
-- 10. Receiver: individuals, students and NGOs who collect food
-- ---------------------------------------------------------------------
CREATE TABLE Receiver (
    receiver_id   INT AUTO_INCREMENT PRIMARY KEY,
    name          VARCHAR(80)  NOT NULL,
    phone         VARCHAR(15)  NOT NULL UNIQUE,
    email         VARCHAR(100) UNIQUE,
    receiver_type VARCHAR(12)  NOT NULL DEFAULT 'INDIVIDUAL',
    CONSTRAINT chk_receiver_type CHECK (receiver_type IN ('INDIVIDUAL','STUDENT','NGO'))
);

-- ---------------------------------------------------------------------
-- 11. Reservation: a 45-minute hold at ONE donor.
--     expires_at is derived: reserved_at + INTERVAL 45 MINUTE.
-- ---------------------------------------------------------------------
CREATE TABLE Reservation (
    reservation_id INT AUTO_INCREMENT PRIMARY KEY,
    receiver_id    INT         NOT NULL,
    donor_id       INT         NOT NULL,
    status         VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    reserved_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_res_status CHECK (status IN ('ACTIVE','COLLECTED','EXPIRED','CANCELLED')),
    CONSTRAINT fk_res_receiver FOREIGN KEY (receiver_id) REFERENCES Receiver(receiver_id),
    CONSTRAINT fk_res_donor    FOREIGN KEY (donor_id)    REFERENCES Donor(donor_id)
);

-- ---------------------------------------------------------------------
-- 12. Reservation_Item: resolves Reservation M:N Food_Item ("holds").
--     price_at_reservation is a snapshot, not a copy of Listing's price.
-- ---------------------------------------------------------------------
CREATE TABLE Reservation_Item (
    reservation_id       INT NOT NULL,
    item_id              INT NOT NULL,
    quantity             INT NOT NULL,
    price_at_reservation DECIMAL(8,2) NOT NULL,
    PRIMARY KEY (reservation_id, item_id),
    CONSTRAINT chk_ritem_qty   CHECK (quantity > 0),
    CONSTRAINT chk_ritem_price CHECK (price_at_reservation >= 0),
    CONSTRAINT fk_ritem_res  FOREIGN KEY (reservation_id) REFERENCES Reservation(reservation_id) ON DELETE CASCADE,
    CONSTRAINT fk_ritem_item FOREIGN KEY (item_id)        REFERENCES Food_Item(item_id)
);

-- ---------------------------------------------------------------------
-- 13. Reservation_Batch: which batch(es) a reserved item was taken from
--     (FEFO can split one item across two batches). Needed so an expired
--     or cancelled hold can return the exact units to the exact batch.
-- ---------------------------------------------------------------------
CREATE TABLE Reservation_Batch (
    reservation_id INT         NOT NULL,
    item_id        INT         NOT NULL,
    donor_id       INT         NOT NULL,
    batch_no       VARCHAR(20) NOT NULL,
    quantity       INT         NOT NULL,
    PRIMARY KEY (reservation_id, item_id, batch_no),
    CONSTRAINT chk_rbatch_qty CHECK (quantity > 0),
    CONSTRAINT fk_rbatch_ritem FOREIGN KEY (reservation_id, item_id)
        REFERENCES Reservation_Item(reservation_id, item_id) ON DELETE CASCADE,
    CONSTRAINT fk_rbatch_batch FOREIGN KEY (donor_id, item_id, batch_no)
        REFERENCES Food_Batch(donor_id, item_id, batch_no)
);

-- ---------------------------------------------------------------------
-- 14. Search_Log: every search, for demand insights. Guests allowed.
-- ---------------------------------------------------------------------
CREATE TABLE Search_Log (
    search_id    INT AUTO_INCREMENT PRIMARY KEY,
    receiver_id  INT,                                   -- NULL = searched without logging in
    item_id      INT          NOT NULL,
    latitude     DECIMAL(9,6) NOT NULL,
    longitude    DECIMAL(9,6) NOT NULL,
    searched_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    donors_found INT          NOT NULL DEFAULT 0,
    CONSTRAINT chk_search_found CHECK (donors_found >= 0),
    CONSTRAINT fk_search_receiver FOREIGN KEY (receiver_id) REFERENCES Receiver(receiver_id) ON DELETE SET NULL,
    CONSTRAINT fk_search_item     FOREIGN KEY (item_id)     REFERENCES Food_Item(item_id)
);

-- ---------------------------------------------------------------------
-- 15. Feedback: one rating per collected reservation
-- ---------------------------------------------------------------------
CREATE TABLE Feedback (
    feedback_id    INT AUTO_INCREMENT PRIMARY KEY,
    reservation_id INT NOT NULL UNIQUE,
    rating         TINYINT NOT NULL,
    comment        VARCHAR(200),
    given_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_feedback_rating CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT fk_feedback_res FOREIGN KEY (reservation_id) REFERENCES Reservation(reservation_id) ON DELETE CASCADE
);


-- =====================================================================
-- SAMPLE DATA (parents before children, because of the foreign keys)
-- Demo clock used everywhere: Thursday 5 Nov 2026, 8:30 PM.
-- =====================================================================
INSERT INTO Admin (admin_id, name, email, phone) VALUES
(1, 'Kavita Menon',  'kavita.admin@foodrescue.in', '9819000101'),
(2, 'Rahul Bhosale', 'rahul.admin@foodrescue.in',  '9819000102');

-- Seven donors: five verified, one pending (not yet reviewed), one rejected.
INSERT INTO Donor (donor_id, fssai_no, name, donor_type, address, area, pincode, latitude, longitude, phone, status, verified_by, verified_at) VALUES
(1, '11520012000101', 'Gulab Sweets & Bakers',    'BAKERY',      'Shop 4, Bhavan''s College Rd',      'Andheri West',    '400058', 19.123500, 72.836000, '9820022201', 'VERIFIED', 1, '2026-09-02 11:20:00'),
(2, '11520012000202', 'Spice Route Restaurant',   'RESTAURANT',  '21, Teli Gali, Near Station',       'Andheri East',    '400069', 19.119000, 72.847000, '9820022202', 'VERIFIED', 1, '2026-09-03 12:05:00'),
(3, '11520012000303', 'Midnight Bakehouse 24x7',  'BAKERY',      'JP Rd, Near Andheri Sports Complex','Andheri West',    '400058', 19.129000, 72.830000, '9820022203', 'VERIFIED', 2, '2026-09-05 20:10:00'),
(4, '11520012000404', 'Juhu Caterers',            'CATERER',     '8, Nehru Rd, Vile Parle',           'Vile Parle West', '400056', 19.103000, 72.840000, '9820022204', 'VERIFIED', 2, '2026-09-06 16:40:00'),
(5, '11520012000505', 'Goregaon Tiffin Kitchen',  'CANTEEN',     'MG Rd, Goregaon',                   'Goregaon West',   '400104', 19.164600, 72.849300, '9820022205', 'PENDING',  NULL, NULL),
(6, '11520012000606', 'Santacruz Quick Bites',    'RESTAURANT',  'Linking Rd, Santacruz',             'Santacruz West',  '400054', 19.081000, 72.837000, '9820022206', 'REJECTED', 1, '2026-10-10 09:45:00'),
(7, '11520012000707', 'Fresh Basket Mart',        'SUPERMARKET', 'Lokhandwala Complex, Andheri',      'Andheri West',    '400053', 19.118000, 72.833000, '9820022207', 'VERIFIED', 1, '2026-09-12 10:30:00');

-- Pickup windows (1 = Sunday ... 7 = Saturday).
INSERT INTO Donor_Hours (donor_id, day_of_week, pickup_from, pickup_to) VALUES
(1,1,'19:00','23:00'),(1,2,'19:00','23:00'),(1,3,'19:00','23:00'),(1,4,'19:00','23:00'),(1,5,'19:00','23:00'),(1,6,'19:00','23:00'),(1,7,'19:00','23:00'),
(2,1,'20:00','23:30'),(2,2,'20:00','23:30'),(2,3,'20:00','23:30'),(2,4,'20:00','23:30'),(2,5,'20:00','23:30'),(2,6,'20:00','23:30'),(2,7,'20:00','23:30'),
(3,1,'00:00','23:59:59'),(3,2,'00:00','23:59:59'),(3,3,'00:00','23:59:59'),(3,4,'00:00','23:59:59'),(3,5,'00:00','23:59:59'),(3,6,'00:00','23:59:59'),(3,7,'00:00','23:59:59'),
(4,2,'18:00','22:00'),(4,3,'18:00','22:00'),(4,4,'18:00','22:00'),(4,5,'18:00','22:00'),(4,6,'18:00','22:00'),(4,7,'18:00','22:00'),
(5,1,'19:00','22:00'),(5,2,'19:00','22:00'),(5,3,'19:00','22:00'),(5,4,'19:00','22:00'),(5,5,'19:00','22:00'),(5,6,'19:00','22:00'),(5,7,'19:00','22:00'),
(6,1,'19:00','22:00'),(6,2,'19:00','22:00'),(6,3,'19:00','22:00'),(6,4,'19:00','22:00'),(6,5,'19:00','22:00'),(6,6,'19:00','22:00'),(6,7,'19:00','22:00'),
(7,1,'21:00','23:00'),(7,2,'21:00','23:00'),(7,3,'21:00','23:00'),(7,4,'21:00','23:00'),(7,5,'21:00','23:00'),(7,6,'21:00','23:00'),(7,7,'21:00','23:00');
-- Midnight Bakehouse is open 24 hours; Juhu Caterers is closed on Sundays (no day 1 row);
-- Fresh Basket Mart opens its pickup window only at 9 PM (closed at the 8:30 PM demo time).

-- Thirteen food items (Jain Thali is intentionally listed nowhere).
INSERT INTO Food_Item (item_id, item_name, category, diet_type, unit, max_shelf_hours, requires_refrigeration) VALUES
( 1, 'Veg Biryani',          'COOKED',    'VEG',    'portion',    8, FALSE),
( 2, 'Paneer Butter Masala', 'COOKED',    'VEG',    'portion',    8, FALSE),
( 3, 'Chicken Curry',        'COOKED',    'NONVEG', 'portion',    6, FALSE),
( 4, 'Dal Tadka',            'COOKED',    'VEG',    'portion',    8, FALSE),
( 5, 'Butter Croissant',     'BAKERY',    'VEG',    'piece',     24, FALSE),
( 6, 'Whole Wheat Bread',    'BAKERY',    'VEG',    'piece',     48, FALSE),
( 7, 'Chocolate Pastry',     'BAKERY',    'VEG',    'piece',     24, FALSE),
( 8, 'Curd Cup',             'DAIRY',     'VEG',    'packet',    72, TRUE),
( 9, 'Fresh Fruit Salad',    'FRUIT_VEG', 'VEGAN',  'portion',   12, TRUE),
(10, 'Mango Juice Pack',     'BEVERAGE',  'VEGAN',  'packet',  1440, FALSE),
(11, 'Veg Sandwich',         'PACKAGED',  'VEG',    'piece',     12, TRUE),
(12, 'Jain Thali',           'COOKED',    'VEG',    'portion',    8, FALSE),
(13, 'Loose Vegetables',     'FRUIT_VEG', 'VEGAN',  'kg',        48, FALSE);

INSERT INTO Allergen (allergen_id, allergen_name) VALUES
(1,'Gluten'),(2,'Milk'),(3,'Egg'),(4,'Tree Nuts'),(5,'Soy'),(6,'Peanuts');

INSERT INTO Item_Allergen (item_id, allergen_id) VALUES
(1,2),
(2,2),(2,4),
(5,1),(5,2),(5,3),
(6,1),
(7,1),(7,2),(7,3),
(8,2),
(11,1),(11,2),(11,5),
(12,1),(12,2);

-- Listings: rescue price per unit (0 = free), optional time-limited flash discount.
INSERT INTO Listing (donor_id, item_id, price_per_unit, discount_percent, discount_valid_till) VALUES
-- 1 Gulab Sweets & Bakers
(1, 5, 25.00, 20, '2026-11-05 22:00:00'),
(1, 6, 20.00,  0, NULL),
(1, 7, 30.00,  0, NULL),
(1,11, 35.00,  0, NULL),
-- 2 Spice Route Restaurant (Chicken Curry discount ended yesterday: counts as 0)
(2, 1, 60.00, 25, '2026-11-05 21:30:00'),
(2, 2, 70.00,  0, NULL),
(2, 3, 80.00, 10, '2026-11-04 23:00:00'),
(2, 4, 35.00,  0, NULL),
-- 3 Midnight Bakehouse 24x7
(3, 5, 22.00,  0, NULL),
(3, 6, 18.00,  0, NULL),
(3, 7, 28.00, 10, NULL),
(3,11, 30.00,  0, NULL),
-- 4 Juhu Caterers
(4, 1, 50.00,  0, NULL),
(4, 2, 65.00,  0, NULL),
(4, 3, 75.00,  0, NULL),
(4, 4, 28.00,  0, NULL),
(4, 9, 40.00,  0, NULL),
-- 5 Goregaon Tiffin Kitchen (PENDING)
(5, 1, 55.00,  0, NULL),
(5, 8, 14.00,  0, NULL),
-- 6 Santacruz Quick Bites (REJECTED)
(6, 5, 20.00,  0, NULL),
-- 7 Fresh Basket Mart
(7, 6, 16.00,  0, NULL),
(7, 8, 12.00, 15, NULL),
(7, 9, 38.00,  0, NULL),
(7,10, 18.00,  0, NULL),
(7,13, 25.00,  0, NULL);

-- Food batches. Edge cases: MB-PS-OLD and MB-SW-OLD are already past best-before;
-- JC-CC-1 is sold out (qty 0); SR-BI-A and SR-CC-A expire within the next 90 minutes.
-- The *-110x batches (qty 0) are the old stock behind historical reservations.
INSERT INTO Food_Batch (donor_id, item_id, batch_no, prepared_at, best_before, quantity, listed_at) VALUES
-- 1 Gulab Sweets & Bakers
(1, 5, 'GS-CR-1105', '2026-11-05 08:00:00', '2026-11-06 08:00:00', 18, '2026-11-05 19:00:00'),
(1, 5, 'GS-CR-1104', '2026-11-04 08:00:00', '2026-11-05 08:00:00',  0, '2026-11-04 19:00:00'),
(1, 6, 'GS-BR-1104', '2026-11-04 07:00:00', '2026-11-06 07:00:00', 10, '2026-11-05 19:00:00'),
(1, 7, 'GS-PS-1105', '2026-11-05 10:00:00', '2026-11-06 10:00:00', 12, '2026-11-05 19:00:00'),
(1,11, 'GS-SW-1105', '2026-11-05 12:00:00', '2026-11-06 00:00:00',  8, '2026-11-05 19:00:00'),
(1,11, 'GS-SW-1104', '2026-11-04 12:00:00', '2026-11-05 00:00:00',  0, '2026-11-04 19:00:00'),
-- 2 Spice Route Restaurant
(2, 1, 'SR-BI-A',    '2026-11-05 14:00:00', '2026-11-05 22:00:00', 20, '2026-11-05 20:05:00'),
(2, 1, 'SR-BI-B',    '2026-11-05 18:30:00', '2026-11-06 02:30:00', 15, '2026-11-05 20:05:00'),
(2, 1, 'SR-BI-1104', '2026-11-04 14:00:00', '2026-11-04 22:00:00',  0, '2026-11-04 20:05:00'),
(2, 2, 'SR-PB-A',    '2026-11-05 17:00:00', '2026-11-06 01:00:00', 14, '2026-11-05 20:05:00'),
(2, 3, 'SR-CC-A',    '2026-11-05 15:00:00', '2026-11-05 21:00:00',  9, '2026-11-05 20:05:00'),
(2, 4, 'SR-DT-A',    '2026-11-05 16:00:00', '2026-11-06 00:00:00', 22, '2026-11-05 20:05:00'),
(2, 4, 'SR-DT-1104', '2026-11-04 16:00:00', '2026-11-05 00:00:00',  0, '2026-11-04 20:05:00'),
-- 3 Midnight Bakehouse 24x7
(3, 5, 'MB-CR-1',    '2026-11-05 06:00:00', '2026-11-06 06:00:00', 30, '2026-11-05 07:00:00'),
(3, 6, 'MB-BR-1',    '2026-11-04 06:00:00', '2026-11-06 06:00:00', 22, '2026-11-04 07:00:00'),
(3, 7, 'MB-PS-OLD',  '2026-11-04 06:00:00', '2026-11-05 06:00:00', 16, '2026-11-04 07:00:00'),
(3, 7, 'MB-PS-NEW',  '2026-11-05 06:00:00', '2026-11-06 06:00:00', 20, '2026-11-05 07:00:00'),
(3,11, 'MB-SW-OLD',  '2026-11-04 08:00:00', '2026-11-04 20:00:00', 12, '2026-11-04 09:00:00'),
-- 4 Juhu Caterers
(4, 1, 'JC-BI-1',    '2026-11-05 15:30:00', '2026-11-05 23:30:00', 40, '2026-11-05 19:00:00'),
(4, 1, 'JC-BI-1103', '2026-11-03 15:30:00', '2026-11-03 23:30:00',  0, '2026-11-03 19:00:00'),
(4, 2, 'JC-PB-1',    '2026-11-05 15:30:00', '2026-11-05 23:30:00', 35, '2026-11-05 19:00:00'),
(4, 3, 'JC-CC-1',    '2026-11-05 15:00:00', '2026-11-05 21:00:00',  0, '2026-11-05 19:00:00'),
(4, 4, 'JC-DT-1',    '2026-11-05 15:30:00', '2026-11-05 23:30:00', 30, '2026-11-05 19:00:00'),
(4, 9, 'JC-FS-1',    '2026-11-05 14:00:00', '2026-11-06 02:00:00', 20, '2026-11-05 19:00:00'),
-- 5 Goregaon Tiffin Kitchen (PENDING)
(5, 1, 'GT-BI-1',    '2026-11-05 15:00:00', '2026-11-05 23:00:00', 25, '2026-11-05 19:30:00'),
(5, 8, 'GT-CD-1',    '2026-11-03 09:00:00', '2026-11-06 09:00:00', 30, '2026-11-05 19:30:00'),
-- 6 Santacruz Quick Bites (REJECTED)
(6, 5, 'SQ-CR-1',    '2026-11-05 07:00:00', '2026-11-06 07:00:00', 12, '2026-11-05 19:30:00'),
-- 7 Fresh Basket Mart
(7, 6, 'FB-BR-1',    '2026-11-05 05:00:00', '2026-11-07 05:00:00', 15, '2026-11-05 19:00:00'),
(7, 8, 'FB-CD-1',    '2026-11-04 09:00:00', '2026-11-07 09:00:00', 60, '2026-11-05 19:00:00'),
(7, 9, 'FB-FS-1',    '2026-11-05 13:00:00', '2026-11-06 01:00:00', 24, '2026-11-05 19:00:00'),
(7,10, 'FB-MJ-1',    '2026-10-20 09:00:00', '2026-12-01 09:00:00',100, '2026-11-05 19:00:00'),
(7,13, 'FB-LV-1',    '2026-11-05 06:00:00', '2026-11-07 06:00:00', 35, '2026-11-05 19:00:00');

-- Every batch is logged as LISTED. From Exp 9, a trigger fills this table.
INSERT INTO Batch_Log (donor_id, item_id, batch_no, old_qty, new_qty, reason, logged_at)
SELECT donor_id, item_id, batch_no, 0, quantity, 'LISTED', listed_at
FROM Food_Batch;

INSERT INTO Receiver (receiver_id, name, phone, email, receiver_type) VALUES
(1, 'Aarav Mehta',          '9867002001', 'aarav.mehta@example.com', 'INDIVIDUAL'),
(2, 'Priya Nair',           '9867002002', 'priya.nair@example.com',  'STUDENT'),
(3, 'Asha Foundation',      '9867002003', 'help@ashafoundation.example', 'NGO'),
(4, 'Roti Bank Mumbai',     '9867002004', 'team@rotibank.example',   'NGO'),
(5, 'Sneha Kulkarni',       '9867002005', NULL,                      'INDIVIDUAL');

-- Reservations: one in each status, plus a second collected one. Hold = 45 minutes.
INSERT INTO Reservation (reservation_id, receiver_id, donor_id, status, reserved_at) VALUES
(1, 3, 2, 'COLLECTED', '2026-11-04 21:00:00'),
(2, 1, 1, 'COLLECTED', '2026-11-04 20:15:00'),
(3, 2, 4, 'EXPIRED',   '2026-11-03 21:00:00'),
(4, 4, 3, 'CANCELLED', '2026-11-05 19:00:00'),
(5, 1, 2, 'ACTIVE',    '2026-11-05 20:10:00'),
(6, 3, 4, 'COLLECTED', '2026-11-05 19:45:00');

INSERT INTO Reservation_Item (reservation_id, item_id, quantity, price_at_reservation) VALUES
(1, 1, 30, 45.00),
(1, 4, 20, 35.00),
(2, 5,  4, 20.00),
(2,11,  2, 35.00),
(3, 1,  2, 50.00),
(4, 6, 10, 18.00),
(5, 4,  3, 35.00),
(6, 1, 15, 50.00),
(6, 9, 10, 40.00);

INSERT INTO Reservation_Batch (reservation_id, item_id, donor_id, batch_no, quantity) VALUES
(1, 1, 2, 'SR-BI-1104', 30),
(1, 4, 2, 'SR-DT-1104', 20),
(2, 5, 1, 'GS-CR-1104',  4),
(2,11, 1, 'GS-SW-1104',  2),
(3, 1, 4, 'JC-BI-1103',  2),
(4, 6, 3, 'MB-BR-1',    10),
(5, 4, 2, 'SR-DT-A',     3),
(6, 1, 4, 'JC-BI-1',    15),
(6, 9, 4, 'JC-FS-1',    10);

-- Searches near Andheri West over the last month. Jain Thali (12) is never found.
INSERT INTO Search_Log (receiver_id, item_id, latitude, longitude, searched_at, donors_found) VALUES
(1,    1, 19.121500, 72.834800, '2026-11-04 20:40:00', 3),
(1,    5, 19.121500, 72.834800, '2026-11-04 20:05:00', 3),
(3,    1, 19.119500, 72.846000, '2026-11-04 20:50:00', 3),
(2,    1, 19.104000, 72.841000, '2026-11-03 20:45:00', 2),
(NULL, 4, 19.120000, 72.837700, '2026-11-02 21:15:00', 3),
(NULL, 6, 19.124000, 72.833000, '2026-11-01 19:30:00', 3),
(4,    7, 19.128000, 72.831000, '2026-10-30 22:20:00', 2),
(NULL, 9, 19.108000, 72.827500, '2026-10-28 20:10:00', 2),
(NULL,12, 19.123500, 72.836500, '2026-11-04 21:00:00', 0),
(1,   12, 19.122800, 72.835800, '2026-11-05 12:10:00', 0),
(5,   12, 19.124000, 72.834000, '2026-11-02 19:40:00', 0),
(NULL,12, 19.104500, 72.839000, '2026-10-31 20:20:00', 0),
(2,    3, 19.121000, 72.835000, '2026-11-01 21:30:00', 0),
(NULL, 3, 19.122000, 72.836000, '2026-10-29 20:50:00', 0);

INSERT INTO Feedback (feedback_id, reservation_id, rating, comment, given_at) VALUES
(1, 1, 5, 'Hot and fresh, fed 50 people at our shelter.', '2026-11-04 22:30:00'),
(2, 2, 4, 'Croissants were great, sandwich a bit dry.',    '2026-11-04 21:30:00'),
(3, 6, 5, 'Very quick handover, caterer was helpful.',     '2026-11-05 20:15:00');
