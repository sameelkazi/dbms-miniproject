-- =====================================================================
-- Surplus Food Rescue | DBMS Mini Project | Exp 8 (Phase II)
-- Twenty SQL queries: joins (Q1-Q7), aggregates (Q8-Q13), subqueries (Q14-Q20).
-- Run exp7_schema_and_data.sql first. Target: MySQL 8.0.16 or later.
-- =====================================================================
USE food_rescue;

-- A fixed demo time and location are set once so every result is reproducible.
-- In the live app these become NOW() and the phone's GPS.
SET @at     = '2026-11-05 20:30:00';   -- Thursday 5 Nov 2026, 8:30 PM
SET @today  = DATE(@at);
SET @my_lat = 19.1215;                 -- a receiver standing near Andheri West
SET @my_lng = 72.8348;

-- =====================================================================
-- A. JOINS
-- =====================================================================

-- Q1 Verified donors and the admin who verified each (INNER JOIN)
SELECT d.donor_id,
       d.name        AS donor,
       d.donor_type,
       d.area,
       a.name        AS verified_by,
       d.verified_at
FROM Donor d
INNER JOIN Admin a ON a.admin_id = d.verified_by
WHERE d.status = 'VERIFIED'
ORDER BY d.verified_at;

-- Q2 Every donor and its review status (LEFT JOIN)
SELECT d.name                                   AS donor,
       d.status,
       COALESCE(a.name, 'Not reviewed yet')     AS reviewed_by
FROM Donor d
LEFT JOIN Admin a ON a.admin_id = d.verified_by
ORDER BY FIELD(d.status, 'PENDING', 'REJECTED', 'VERIFIED'), d.name;

-- Q3 Full details of a reservation (five-table join, with a derived expiry)
SELECT r.reservation_id,
       rc.name                                  AS receiver,
       rc.receiver_type,
       dn.name                                  AS donor,
       r.reserved_at,
       r.reserved_at + INTERVAL 45 MINUTE       AS hold_expires_at,
       fi.item_name,
       ri.quantity,
       fi.unit,
       ri.price_at_reservation,
       ri.quantity * ri.price_at_reservation    AS line_total
FROM Reservation r
JOIN Receiver         rc ON rc.receiver_id    = r.receiver_id
JOIN Donor            dn ON dn.donor_id       = r.donor_id
JOIN Reservation_Item ri ON ri.reservation_id = r.reservation_id
JOIN Food_Item        fi ON fi.item_id        = ri.item_id
WHERE r.reservation_id = 6
ORDER BY fi.item_id;

-- Q4 Allergen sheet for every item (JOIN through the junction table)
SELECT fi.item_name,
       fi.diet_type,
       COALESCE(GROUP_CONCAT(al.allergen_name ORDER BY al.allergen_name SEPARATOR ', '),
                'None declared') AS contains_allergens
FROM Food_Item fi
LEFT JOIN Item_Allergen ia ON ia.item_id    = fi.item_id
LEFT JOIN Allergen      al ON al.allergen_id = ia.allergen_id
GROUP BY fi.item_id, fi.item_name, fi.diet_type
ORDER BY fi.item_id;

-- Q5 Pairs of verified donors in the same area (SELF JOIN)
SELECT d1.area,
       d1.name AS donor_1,
       d2.name AS donor_2
FROM Donor d1
JOIN Donor d2
  ON d1.area = d2.area
 AND d1.donor_id < d2.donor_id
WHERE d1.status = 'VERIFIED'
  AND d2.status = 'VERIFIED'
ORDER BY d1.donor_id, d2.donor_id;

-- Q6 Food items nobody lists (anti-join)
SELECT fi.item_id,
       fi.item_name,
       fi.category
FROM Food_Item fi
LEFT JOIN Listing l ON l.item_id = fi.item_id
WHERE l.item_id IS NULL
ORDER BY fi.item_id;

-- Q7 The main search: "Where can I get Veg Biryani right now?"
-- Verified donors, pickup window open for at least 30 more minutes, unexpired stock
-- summed to one quantity per donor, nearest first (Haversine distance).
SELECT d.name                                   AS donor,
       d.area,
       d.phone,
       ROUND(6371 * 2 * ASIN(SQRT(
             POWER(SIN(RADIANS(d.latitude - @my_lat) / 2), 2)
           + COS(RADIANS(@my_lat)) * COS(RADIANS(d.latitude))
           * POWER(SIN(RADIANS(d.longitude - @my_lng) / 2), 2))), 2) AS distance_km,
       SUM(b.quantity)                          AS available_qty,
       l.price_per_unit,
       CASE WHEN l.discount_valid_till IS NULL OR l.discount_valid_till >= @at
            THEN l.discount_percent ELSE 0 END  AS discount_pct,
       ROUND(l.price_per_unit * (1 - CASE WHEN l.discount_valid_till IS NULL
                                           OR l.discount_valid_till >= @at
                                          THEN l.discount_percent ELSE 0 END / 100), 2) AS final_price,
       h.pickup_to                              AS pickup_till,
       ROUND(TIMESTAMPDIFF(MINUTE, @at, MIN(b.best_before)) / 60, 1) AS earliest_batch_hours_left
FROM Food_Item fi
JOIN Listing      l ON l.item_id  = fi.item_id
JOIN Food_Batch   b ON b.donor_id = l.donor_id AND b.item_id = l.item_id
JOIN Donor        d ON d.donor_id = l.donor_id
JOIN Donor_Hours  h ON h.donor_id = d.donor_id
                   AND h.day_of_week = DAYOFWEEK(@at)
                   AND TIME(@at) BETWEEN h.pickup_from AND SUBTIME(h.pickup_to, '00:30:00')
WHERE fi.item_name = 'Veg Biryani'
  AND d.status = 'VERIFIED'
  AND b.best_before > @at
GROUP BY d.donor_id, d.name, d.area, d.phone, d.latitude, d.longitude,
         l.price_per_unit, l.discount_percent, l.discount_valid_till, h.pickup_to
HAVING SUM(b.quantity) > 0
ORDER BY distance_km;

-- =====================================================================
-- B. AGGREGATE FUNCTIONS
-- =====================================================================

-- Q8 Inventory summary per donor (unexpired stock only)
SELECT d.name                                   AS donor,
       COUNT(DISTINCT b.item_id)                AS items_in_stock,
       SUM(b.quantity)                          AS total_units,
       ROUND(SUM(b.quantity * l.price_per_unit), 2) AS stock_value_rs
FROM Donor d
JOIN Listing    l ON l.donor_id = d.donor_id
JOIN Food_Batch b ON b.donor_id = l.donor_id AND b.item_id = l.item_id
WHERE d.status = 'VERIFIED'
  AND b.best_before > @at
GROUP BY d.donor_id, d.name
ORDER BY stock_value_rs DESC;

-- Q9 Price comparison per item (MIN / MAX / AVG of the final price)
-- Only items offered by two or more verified donors.
SELECT fi.item_name,
       fi.unit,
       COUNT(*)                         AS donors,
       ROUND(MIN(fp.final_price), 2)    AS cheapest,
       ROUND(MAX(fp.final_price), 2)    AS costliest,
       ROUND(AVG(fp.final_price), 2)    AS average_price
FROM (
    SELECT l.item_id,
           l.price_per_unit * (1 - CASE WHEN l.discount_valid_till IS NULL
                                         OR l.discount_valid_till >= @at
                                        THEN l.discount_percent ELSE 0 END / 100) AS final_price
    FROM Listing l
    JOIN Donor d ON d.donor_id = l.donor_id
    WHERE d.status = 'VERIFIED'
) AS fp
JOIN Food_Item fi ON fi.item_id = fp.item_id
GROUP BY fi.item_id, fi.item_name, fi.unit
HAVING COUNT(*) >= 2
ORDER BY (MAX(fp.final_price) - MIN(fp.final_price)) DESC, fi.item_name;

-- Q10 Reservations by status (COUNT + GROUP BY)
SELECT status,
       COUNT(*) AS reservations
FROM Reservation
GROUP BY status
ORDER BY reservations DESC, status;

-- Q11 Batches expiring in the next 3 hours, per donor (MIN, SUM, COUNT)
-- Flags food a donor should push out fast before it is wasted.
SELECT d.name                          AS donor,
       COUNT(*)                        AS batches_expiring,
       SUM(b.quantity)                 AS units_at_risk,
       MIN(b.best_before)              AS earliest_best_before
FROM Food_Batch b
JOIN Donor d ON d.donor_id = b.donor_id
WHERE d.status = 'VERIFIED'
  AND b.best_before >  @at
  AND b.best_before <= @at + INTERVAL 3 HOUR
  AND b.quantity > 0
GROUP BY d.donor_id, d.name
ORDER BY earliest_best_before;

-- Q12 Most-searched items and failed searches
SELECT fi.item_name,
       COUNT(*)                                                 AS searches,
       SUM(CASE WHEN sl.donors_found = 0 THEN 1 ELSE 0 END)     AS searches_with_no_result,
       COUNT(DISTINCT sl.receiver_id)                           AS logged_in_searchers
FROM Search_Log sl
JOIN Food_Item fi ON fi.item_id = sl.item_id
GROUP BY fi.item_id, fi.item_name
ORDER BY searches DESC, fi.item_name
LIMIT 5;

-- Q13 Collected orders and food rescued per donor, with average rating
SELECT d.name                                   AS donor,
       COUNT(DISTINCT r.reservation_id)         AS collected_orders,
       SUM(ri.quantity)                         AS units_rescued,
       SUM(ri.quantity * ri.price_at_reservation) AS sales_rs,
       ROUND(AVG(f.rating), 1)                  AS avg_rating
FROM Reservation r
JOIN Donor            d  ON d.donor_id       = r.donor_id
JOIN Reservation_Item ri ON ri.reservation_id = r.reservation_id
LEFT JOIN Feedback    f  ON f.reservation_id  = r.reservation_id
WHERE r.status = 'COLLECTED'
GROUP BY d.donor_id, d.name
ORDER BY units_rescued DESC;

-- =====================================================================
-- C. SUBQUERIES
-- =====================================================================

-- Q14 Where is Veg Biryani cheapest? (scalar subquery)
SELECT d.name AS donor,
       d.area,
       l.price_per_unit
FROM Listing l
JOIN Donor d ON d.donor_id = l.donor_id
WHERE d.status = 'VERIFIED'
  AND l.item_id = (SELECT item_id FROM Food_Item WHERE item_name = 'Veg Biryani')
  AND l.price_per_unit = (
        SELECT MIN(l2.price_per_unit)
        FROM Listing l2
        JOIN Donor d2 ON d2.donor_id = l2.donor_id
        WHERE d2.status = 'VERIFIED'
          AND l2.item_id = (SELECT item_id FROM Food_Item WHERE item_name = 'Veg Biryani'))
ORDER BY d.donor_id;

-- Q15 Listings priced above their item's average (correlated subquery)
SELECT d.name AS donor,
       fi.item_name,
       l.price_per_unit,
       (SELECT ROUND(AVG(l2.price_per_unit), 2)
        FROM Listing l2 JOIN Donor d2 ON d2.donor_id = l2.donor_id
        WHERE l2.item_id = l.item_id AND d2.status = 'VERIFIED') AS item_average
FROM Listing l
JOIN Donor     d  ON d.donor_id = l.donor_id
JOIN Food_Item fi ON fi.item_id = l.item_id
WHERE d.status = 'VERIFIED'
  AND l.price_per_unit > (
        SELECT AVG(l2.price_per_unit)
        FROM Listing l2
        JOIN Donor d2 ON d2.donor_id = l2.donor_id
        WHERE l2.item_id = l.item_id
          AND d2.status = 'VERIFIED')
ORDER BY fi.item_name, l.price_per_unit DESC, d.name;

-- Q16 Receivers who never reserved (NOT EXISTS)
SELECT rc.receiver_id,
       rc.name,
       rc.receiver_type,
       rc.phone
FROM Receiver rc
WHERE NOT EXISTS (
    SELECT 1
    FROM Reservation r
    WHERE r.receiver_id = rc.receiver_id
)
ORDER BY rc.receiver_id;

-- Q17 Donors who have earned a 5-star rating (nested IN)
-- Three nested IN subqueries walk from 5-star feedback to reservations to donors.
SELECT d.name,
       d.donor_type,
       d.area
FROM Donor d
WHERE d.donor_id IN (
    SELECT r.donor_id
    FROM Reservation r
    WHERE r.reservation_id IN (
        SELECT f.reservation_id
        FROM Feedback f
        WHERE f.rating = 5
    )
)
ORDER BY d.donor_id;

-- Q18 Donors holding more than the average stock (derived table)
-- A subquery in FROM builds per-donor totals; a second derived table supplies the average.
SELECT inv.donor,
       inv.total_units
FROM (
    SELECT d.name AS donor, SUM(b.quantity) AS total_units
    FROM Donor d
    JOIN Food_Batch b ON b.donor_id = d.donor_id
    WHERE d.status = 'VERIFIED' AND b.best_before > @at
    GROUP BY d.donor_id, d.name
) AS inv
WHERE inv.total_units > (
    SELECT AVG(t.total_units)
    FROM (
        SELECT SUM(b.quantity) AS total_units
        FROM Donor d
        JOIN Food_Batch b ON b.donor_id = d.donor_id
        WHERE d.status = 'VERIFIED' AND b.best_before > @at
        GROUP BY d.donor_id
    ) AS t
)
ORDER BY inv.total_units DESC;

-- Q19 Donors who can fulfill all items requested in Reservation 1 (relational division)
-- Relational division using HAVING COUNT: finds verified donors that stock every distinct
-- item present in Reservation 1 (items 1 and 4).
SELECT d.donor_id,
       d.name AS donor_name,
       d.area,
       COUNT(DISTINCT l.item_id) AS items_matched
FROM Donor d
JOIN Listing l ON d.donor_id = l.donor_id
WHERE l.item_id IN (
    SELECT item_id
    FROM Reservation_Item
    WHERE reservation_id = 1
)
  AND d.status = 'VERIFIED'
GROUP BY d.donor_id, d.name, d.area
HAVING COUNT(DISTINCT l.item_id) = (
    SELECT COUNT(*)
    FROM Reservation_Item
    WHERE reservation_id = 1
)
ORDER BY d.donor_id;

-- Q20 Demand insight near a donor (correlated subquery)
-- Items searched within 2 km of Gulab Sweets & Bakers in the last 30 days that it does not
-- list: the seed of the "alert donors to local demand" feature.
SELECT fi.item_name,
       fi.category,
       COUNT(*)            AS nearby_searches,
       MAX(sl.searched_at) AS last_searched
FROM Search_Log sl
JOIN Food_Item fi ON fi.item_id = sl.item_id
JOIN Donor d      ON d.name = 'Gulab Sweets & Bakers'
WHERE sl.searched_at >= @at - INTERVAL 30 DAY
  AND 6371 * 2 * ASIN(SQRT(
          POWER(SIN(RADIANS(sl.latitude - d.latitude) / 2), 2)
        + COS(RADIANS(d.latitude)) * COS(RADIANS(sl.latitude))
        * POWER(SIN(RADIANS(sl.longitude - d.longitude) / 2), 2))) <= 2
  AND NOT EXISTS (
      SELECT 1
      FROM Listing l
      WHERE l.donor_id = d.donor_id
        AND l.item_id  = sl.item_id
  )
GROUP BY fi.item_id, fi.item_name, fi.category
ORDER BY nearby_searches DESC, fi.item_name;
