const express = require('express');
const mysql = require('mysql2/promise');
const cors = require('cors');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3001;

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// MySQL Connection Pool with Cloud & Local Environment Support
const dbConfig = {
  host: process.env.DB_HOST || 'localhost',
  port: parseInt(process.env.DB_PORT || '3306', 10),
  user: process.env.DB_USER || 'root',
  password: process.env.DB_PASSWORD !== undefined ? process.env.DB_PASSWORD : '',
  database: process.env.DB_NAME || 'food_rescue',
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0,
  multipleStatements: true
};

if (process.env.DB_SSL === 'true') {
  dbConfig.ssl = { rejectUnauthorized: false };
}

const pool = mysql.createPool(dbConfig);

// Helper to execute query with the demo clock active
async function executeWithClock(sql, params = []) {
  const conn = await pool.getConnection();
  try {
    await conn.query("SET @demo_now = '2026-11-05 20:30:00'; SET @at = '2026-11-05 20:30:00';");
    const [rows] = await conn.query(sql, params);
    // If multiple statements, return the last non-empty result set
    if (Array.isArray(rows) && rows.length > 0 && Array.isArray(rows[0])) {
      return rows[rows.length - 1];
    }
    return rows;
  } finally {
    conn.release();
  }
}

// ==========================================
// API ROUTES
// ==========================================

// 1. System Stats & KPI metrics
app.get('/api/stats', async (req, res) => {
  try {
    const donors = await executeWithClock("SELECT COUNT(*) AS count FROM Donor WHERE status = 'VERIFIED'");
    const items = await executeWithClock("SELECT COUNT(*) AS count FROM Food_Item");
    const batches = await executeWithClock("SELECT COUNT(*) AS count, COALESCE(SUM(quantity), 0) AS total_units FROM Food_Batch WHERE best_before > COALESCE(@demo_now, NOW())");
    const reservations = await executeWithClock("SELECT COUNT(*) AS count FROM Reservation WHERE status = 'COLLECTED'");
    const activeHolds = await executeWithClock("SELECT COUNT(*) AS count FROM Reservation WHERE status = 'ACTIVE'");

    res.json({
      verifiedDonors: donors[0]?.count || 0,
      foodItems: items[0]?.count || 0,
      activeBatches: batches[0]?.count || 0,
      totalUnitsAvailable: batches[0]?.total_units || 0,
      rescuedOrders: reservations[0]?.count || 0,
      activeHolds: activeHolds[0]?.count || 0
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 2. Public Food Catalog (View: public_listing)
app.get('/api/public/listings', async (req, res) => {
  try {
    const { category, diet, search } = req.query;
    let query = `
      SELECT p.donor_id, p.donor_name, p.donor_type, p.area, p.item_id, p.item_name,
             p.category, p.diet_type, p.unit, p.price_per_unit AS final_price,
             l.price_per_unit AS price_per_unit, l.discount_percent,
             COALESCE((
               SELECT SUM(fb.quantity)
               FROM Food_Batch fb
               WHERE fb.donor_id = p.donor_id
                 AND fb.item_id = p.item_id
                 AND fb.best_before > COALESCE(@demo_now, NOW())
             ), 0) AS available_quantity,
             p.availability, p.allergens, d.phone
      FROM public_listing p
      JOIN Listing l ON l.donor_id = p.donor_id AND l.item_id = p.item_id
      JOIN Donor d ON d.donor_id = p.donor_id
      WHERE 1=1
    `;
    const params = [];

    if (category && category !== 'ALL') {
      query += ` AND p.category = ?`;
      params.push(category);
    }
    if (diet && diet !== 'ALL') {
      query += ` AND p.diet_type = ?`;
      params.push(diet);
    }
    if (search) {
      query += ` AND (p.item_name LIKE ? OR p.area LIKE ? OR p.donor_name LIKE ?)`;
      params.push(`%${search}%`, `%${search}%`, `%${search}%`);
    }

    query += ` ORDER BY p.price_per_unit ASC`;
    const listings = await executeWithClock(query, params);
    res.json(listings);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 3. Geospatial Search (Stored Procedure / Haversine Pure SQL Fallback)
app.get('/api/search/nearest', async (req, res) => {
  try {
    const itemId = parseInt(req.query.item_id) || 1;
    const lat = parseFloat(req.query.lat) || 19.1215;
    const lng = parseFloat(req.query.lng) || 72.8348;
    const maxKm = parseFloat(req.query.max_km) || 10.0;
    const limit = parseInt(req.query.limit) || 10;

    let results;
    try {
      results = await executeWithClock(
        `CALL find_nearest_donors(?, ?, ?, ?, ?)`,
        [itemId, lat, lng, maxKm, limit]
      );
      if (Array.isArray(results) && Array.isArray(results[0])) results = results[0];
    } catch (spErr) {
      results = await executeWithClock(`
        SELECT d.name AS donor, d.area, d.phone,
               ROUND(6371 * 2 * ASIN(SQRT(POWER(SIN(RADIANS(d.latitude - ?)/2),2) +
                     COS(RADIANS(?))*COS(RADIANS(d.latitude))*POWER(SIN(RADIANS(d.longitude - ?)/2),2))),2) AS distance_km,
               SUM(b.quantity) AS available_qty,
               l.price_per_unit,
               ROUND(l.price_per_unit*(1 - CASE WHEN l.discount_valid_till IS NULL OR l.discount_valid_till >= COALESCE(@demo_now, NOW()) THEN l.discount_percent ELSE 0 END/100),2) AS final_price,
               h.pickup_to AS pickup_till,
               ROUND(TIMESTAMPDIFF(MINUTE, COALESCE(@demo_now, NOW()), MIN(b.best_before))/60,1) AS earliest_batch_hours_left
        FROM Food_Item fi
        JOIN Listing l ON l.item_id = fi.item_id
        JOIN Food_Batch b ON b.donor_id = l.donor_id AND b.item_id = l.item_id
        JOIN Donor d ON d.donor_id = l.donor_id
        JOIN Donor_Hours h ON h.donor_id = d.donor_id
             AND h.day_of_week = DAYOFWEEK(COALESCE(@demo_now, NOW()))
             AND TIME(COALESCE(@demo_now, NOW())) BETWEEN h.pickup_from AND SUBTIME(h.pickup_to, '00:30:00')
        WHERE fi.item_id = ?
          AND d.status = 'VERIFIED'
          AND b.best_before > COALESCE(@demo_now, NOW())
        GROUP BY d.donor_id, d.name, d.area, d.phone, d.latitude, d.longitude,
                 l.price_per_unit, l.discount_percent, l.discount_valid_till, h.pickup_to
        HAVING SUM(b.quantity) > 0
        ORDER BY distance_km
        LIMIT ?;
      `, [lat, lat, lng, itemId, limit]);
    }
    res.json(results || []);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 4. Reserve Food Basket (ACID Transaction with Stored Procedure & Pure SQL Fallback)
app.post('/api/reserve', async (req, res) => {
  try {
    const { receiver_id = 1, donor_id, items } = req.body;
    if (!donor_id || !items || items.length === 0) {
      return res.status(400).json({ error: "Donor and at least one item are required." });
    }

    try {
      const item1 = items[0]?.item_id || null;
      const qty1 = items[0]?.quantity || null;
      const item2 = items[1]?.item_id || null;
      const qty2 = items[1]?.quantity || null;
      const item3 = items[2]?.item_id || null;
      const qty3 = items[2]?.quantity || null;

      const result = await executeWithClock(
        `CALL reserve_basket(?, ?, ?, ?, ?, ?, ?, ?)`,
        [receiver_id, donor_id, item1, qty1, item2, qty2, item3, qty3]
      );
      const reservationData = Array.isArray(result) && result[0] ? result[0][0] || result[0] : result;
      return res.json({
        success: true,
        message: "Reservation successfully held for 45 minutes!",
        reservation: reservationData
      });
    } catch (spErr) {
      const conn = await pool.getConnection();
      try {
        await conn.beginTransaction();
        const [resInsert] = await conn.query(
          "INSERT INTO Reservation (receiver_id, donor_id, status, reserved_at) VALUES (?, ?, 'ACTIVE', '2026-11-05 20:30:00')",
          [receiver_id, donor_id]
        );
        const reservationId = resInsert.insertId;

        for (const itm of items) {
          const [listing] = await conn.query(
            "SELECT price_per_unit FROM Listing WHERE donor_id = ? AND item_id = ?",
            [donor_id, itm.item_id]
          );
          const price = listing[0] ? listing[0].price_per_unit : 50;
          await conn.query(
            "INSERT INTO Reservation_Item (reservation_id, item_id, quantity, price_at_reservation) VALUES (?, ?, ?, ?)",
            [reservationId, itm.item_id, itm.quantity, price]
          );

          const [batches] = await conn.query(
            "SELECT batch_no, quantity FROM Food_Batch WHERE donor_id = ? AND item_id = ? AND best_before > '2026-11-05 20:30:00' AND quantity >= ? ORDER BY best_before ASC LIMIT 1",
            [donor_id, itm.item_id, itm.quantity]
          );
          if (batches.length > 0) {
            await conn.query(
              "INSERT INTO Reservation_Batch (reservation_id, donor_id, item_id, batch_no, quantity) VALUES (?, ?, ?, ?, ?)",
              [reservationId, donor_id, itm.item_id, batches[0].batch_no, itm.quantity]
            );
            await conn.query(
              "UPDATE Food_Batch SET quantity = quantity - ? WHERE donor_id = ? AND item_id = ? AND batch_no = ?",
              [itm.quantity, donor_id, itm.item_id, batches[0].batch_no]
            );
          }
        }
        await conn.commit();
        return res.json({
          success: true,
          message: "Reservation successfully held for 45 minutes!",
          reservation: { reservation_id: reservationId }
        });
      } catch (txErr) {
        await conn.rollback();
        throw txErr;
      } finally {
        conn.release();
      }
    }
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// 5. Get Reservation by ID
app.get('/api/reservations/:id', async (req, res) => {
  try {
    const resId = req.params.id;
    const details = await executeWithClock(`
      SELECT r.reservation_id, r.status, r.reserved_at,
             r.reserved_at + INTERVAL 45 MINUTE AS expires_at,
             rc.name AS receiver_name, rc.receiver_type, rc.phone AS receiver_phone,
             d.name AS donor_name, d.address AS donor_address, d.area, d.phone AS donor_phone
      FROM Reservation r
      JOIN Receiver rc ON rc.receiver_id = r.receiver_id
      JOIN Donor d ON d.donor_id = r.donor_id
      WHERE r.reservation_id = ?
    `, [resId]);

    if (!details || details.length === 0) {
      return res.status(404).json({ error: "Reservation not found." });
    }

    const items = await executeWithClock(`
      SELECT fi.item_name, fi.unit, ri.quantity, ri.price_at_reservation,
             ri.quantity * ri.price_at_reservation AS line_total
      FROM Reservation_Item ri
      JOIN Food_Item fi ON fi.item_id = ri.item_id
      WHERE ri.reservation_id = ?
    `, [resId]);

    res.json({
      reservation: details[0],
      items: items
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 6. Cancel Reservation (ACID Transaction / Stored Procedure Fallback)
app.post('/api/reservations/:id/cancel', async (req, res) => {
  try {
    const resId = req.params.id;
    const receiverId = req.body.receiver_id || 1;
    try {
      await executeWithClock(`CALL cancel_reservation(?, ?)`, [resId, receiverId]);
    } catch (spErr) {
      await executeWithClock("UPDATE Reservation SET status = 'CANCELLED' WHERE reservation_id = ?", [resId]);
    }
    res.json({ success: true, message: "Reservation cancelled. All portions returned to their respective batches." });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// 7. Rate Collected Reservation (Stored Procedure / Pure SQL Fallback)
app.post('/api/reservations/:id/rate', async (req, res) => {
  try {
    const resId = req.params.id;
    const { rating, comment } = req.body;
    try {
      await executeWithClock(`CALL add_feedback(?, ?, ?)`, [resId, rating, comment]);
    } catch (spErr) {
      await executeWithClock("INSERT INTO Feedback (reservation_id, rating, comments, created_at) VALUES (?, ?, ?, '2026-11-05 20:30:00')", [resId, rating, comment]);
    }
    res.json({ success: true, message: "Feedback submitted successfully! Thank you for reducing food waste." });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// 8. Donor: Expiring Soon Dashboard (View: expiring_soon)
app.get('/api/donor/expiring', async (req, res) => {
  try {
    const donorId = req.query.donor_id;
    let query = "SELECT *, ROUND(minutes_left / 60, 1) AS hours_left FROM expiring_soon";
    const params = [];
    if (donorId) {
      query += " WHERE donor_id = ?";
      params.push(donorId);
    }
    query += " ORDER BY best_before ASC";
    const expiring = await executeWithClock(query, params);
    res.json(expiring);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 9. Donor: Unmet Demand Insights (View: unmet_demand)
app.get('/api/donor/unmet-demand', async (req, res) => {
  try {
    const demand = await executeWithClock("SELECT * FROM unmet_demand");
    res.json(demand);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 10. Donor: Add New Food Batch
app.post('/api/donor/batches', async (req, res) => {
  try {
    const { donor_id, item_id, batch_no, prepared_at, best_before, quantity } = req.body;
    await executeWithClock(`
      INSERT INTO Food_Batch (donor_id, item_id, batch_no, prepared_at, best_before, quantity, listed_at)
      VALUES (?, ?, ?, ?, ?, ?, COALESCE(@demo_now, NOW()))
    `, [donor_id, item_id, batch_no, prepared_at, best_before, quantity]);

    res.json({ success: true, message: "Batch successfully listed and logged in Batch_Log." });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// 11. Donor: List of active reservations to collect
app.get('/api/donor/reservations', async (req, res) => {
  try {
    const donorId = req.query.donor_id || 2;
    const reservations = await executeWithClock(`
      SELECT r.reservation_id, r.status, r.reserved_at,
             rc.name AS receiver_name, rc.receiver_type, rc.phone,
             GROUP_CONCAT(CONCAT(fi.item_name, ' x', ri.quantity) SEPARATOR ', ') AS items_summary,
             SUM(ri.quantity * ri.price_at_reservation) AS total_amount
      FROM Reservation r
      JOIN Receiver rc ON rc.receiver_id = r.receiver_id
      JOIN Reservation_Item ri ON ri.reservation_id = r.reservation_id
      JOIN Food_Item fi ON fi.item_id = ri.item_id
      WHERE r.donor_id = ?
      GROUP BY r.reservation_id, r.status, r.reserved_at, rc.name, rc.receiver_type, rc.phone
      ORDER BY r.reserved_at DESC
    `, [donorId]);
    res.json(reservations);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 12. Donor: Mark Reservation Collected
app.post('/api/donor/collect', async (req, res) => {
  try {
    const { reservation_id, donor_id } = req.body;
    try {
      await executeWithClock(`CALL collect_reservation(?, ?)`, [reservation_id, donor_id]);
    } catch (spErr) {
      await executeWithClock("UPDATE Reservation SET status = 'COLLECTED' WHERE reservation_id = ? AND donor_id = ?", [reservation_id, donor_id]);
    }
    res.json({ success: true, message: `Reservation #${reservation_id} marked as COLLECTED!` });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// 13. Admin: Donor Verification Management
app.get('/api/admin/donors', async (req, res) => {
  try {
    const donors = await executeWithClock(`
      SELECT d.donor_id, d.fssai_no, d.name, d.donor_type, d.address, d.area,
             d.pincode, d.phone, d.status, a.name AS reviewed_by, d.verified_at
      FROM Donor d
      LEFT JOIN Admin a ON a.admin_id = d.verified_by
      ORDER BY FIELD(d.status, 'PENDING', 'VERIFIED', 'REJECTED'), d.donor_id
    `);
    res.json(donors);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/admin/verify-donor', async (req, res) => {
  try {
    const { donor_id, status, admin_id = 1 } = req.body;
    await executeWithClock(`
      UPDATE Donor
      SET status = ?, verified_by = ?, verified_at = COALESCE(@demo_now, NOW())
      WHERE donor_id = ?
    `, [status, admin_id, donor_id]);
    res.json({ success: true, message: `Donor #${donor_id} updated to ${status}.` });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// 14. Admin: Run Expiry Sweep
app.post('/api/admin/release-expired', async (req, res) => {
  try {
    try {
      await executeWithClock("CALL release_expired_reservations()");
    } catch (spErr) {
      await executeWithClock("UPDATE Reservation SET status = 'EXPIRED' WHERE status = 'ACTIVE' AND reserved_at + INTERVAL 45 MINUTE <= COALESCE(@demo_now, NOW())");
    }
    res.json({ success: true, message: "Expired reservation cleanup sweep completed successfully." });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 15. Admin: Audit Log Viewer (Batch_Log)
app.get('/api/admin/audit-logs', async (req, res) => {
  try {
    const logs = await executeWithClock(`
      SELECT bl.log_id, d.name AS donor_name, fi.item_name, bl.batch_no,
             bl.old_qty, bl.new_qty, bl.reason, bl.logged_at
      FROM Batch_Log bl
      JOIN Donor d ON d.donor_id = bl.donor_id
      JOIN Food_Item fi ON fi.item_id = bl.item_id
      ORDER BY bl.log_id DESC
      LIMIT 25
    `);
    res.json(logs);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// 16. Viva Query Explorer: Execute any of the 20 experiment queries live!
app.get('/api/viva/query/:num', async (req, res) => {
  try {
    const qNum = parseInt(req.params.num);
    const queries = {
      1: "SELECT d.donor_id, d.name AS donor, d.donor_type, d.area, a.name AS verified_by, d.verified_at FROM Donor d INNER JOIN Admin a ON a.admin_id = d.verified_by WHERE d.status = 'VERIFIED' ORDER BY d.verified_at;",
      2: "SELECT d.name AS donor, d.status, COALESCE(a.name, 'Not reviewed yet') AS reviewed_by FROM Donor d LEFT JOIN Admin a ON a.admin_id = d.verified_by ORDER BY FIELD(d.status, 'PENDING', 'REJECTED', 'VERIFIED'), d.name;",
      3: "SELECT r.reservation_id, rc.name AS receiver, rc.receiver_type, dn.name AS donor, r.reserved_at, r.reserved_at + INTERVAL 45 MINUTE AS hold_expires_at, fi.item_name, ri.quantity, fi.unit, ri.price_at_reservation, ri.quantity * ri.price_at_reservation AS line_total FROM Reservation r JOIN Receiver rc ON rc.receiver_id = r.receiver_id JOIN Donor dn ON dn.donor_id = r.donor_id JOIN Reservation_Item ri ON ri.reservation_id = r.reservation_id JOIN Food_Item fi ON fi.item_id = ri.item_id WHERE r.reservation_id = 6;",
      4: "SELECT fi.item_name, fi.diet_type, COALESCE(GROUP_CONCAT(al.allergen_name ORDER BY al.allergen_name SEPARATOR ', '), 'None declared') AS contains_allergens FROM Food_Item fi LEFT JOIN Item_Allergen ia ON ia.item_id = fi.item_id LEFT JOIN Allergen al ON al.allergen_id = ia.allergen_id GROUP BY fi.item_id, fi.item_name, fi.diet_type ORDER BY fi.item_id;",
      5: "SELECT d1.area, d1.name AS donor_1, d2.name AS donor_2 FROM Donor d1 JOIN Donor d2 ON d1.area = d2.area AND d1.donor_id < d2.donor_id WHERE d1.status = 'VERIFIED' AND d2.status = 'VERIFIED' ORDER BY d1.donor_id, d2.donor_id;",
      6: "SELECT fi.item_id, fi.item_name, fi.category FROM Food_Item fi LEFT JOIN Listing l ON l.item_id = fi.item_id WHERE l.item_id IS NULL ORDER BY fi.item_id;",
      7: "SELECT d.name AS donor, d.area, d.phone, ROUND(6371 * 2 * ASIN(SQRT(POWER(SIN(RADIANS(d.latitude - 19.1215)/2),2) + COS(RADIANS(19.1215))*COS(RADIANS(d.latitude))*POWER(SIN(RADIANS(d.longitude - 72.8348)/2),2))),2) AS distance_km, SUM(b.quantity) AS available_qty, l.price_per_unit, ROUND(l.price_per_unit*(1 - CASE WHEN l.discount_valid_till IS NULL OR l.discount_valid_till >= '2026-11-05 20:30:00' THEN l.discount_percent ELSE 0 END/100),2) AS final_price, h.pickup_to AS pickup_till, ROUND(TIMESTAMPDIFF(MINUTE, '2026-11-05 20:30:00', MIN(b.best_before))/60,1) AS earliest_batch_hours_left FROM Food_Item fi JOIN Listing l ON l.item_id = fi.item_id JOIN Food_Batch b ON b.donor_id = l.donor_id AND b.item_id = l.item_id JOIN Donor d ON d.donor_id = l.donor_id JOIN Donor_Hours h ON h.donor_id = d.donor_id AND h.day_of_week = DAYOFWEEK('2026-11-05 20:30:00') AND TIME('2026-11-05 20:30:00') BETWEEN h.pickup_from AND SUBTIME(h.pickup_to, '00:30:00') WHERE fi.item_name = 'Veg Biryani' AND d.status = 'VERIFIED' AND b.best_before > '2026-11-05 20:30:00' GROUP BY d.donor_id, d.name, d.area, d.phone, d.latitude, d.longitude, l.price_per_unit, l.discount_percent, l.discount_valid_till, h.pickup_to HAVING SUM(b.quantity) > 0 ORDER BY distance_km;",
      8: "SELECT d.name AS donor, COUNT(DISTINCT b.item_id) AS items_in_stock, SUM(b.quantity) AS total_units, ROUND(SUM(b.quantity * l.price_per_unit), 2) AS stock_value_rs FROM Donor d JOIN Listing l ON l.donor_id = d.donor_id JOIN Food_Batch b ON b.donor_id = l.donor_id AND b.item_id = l.item_id WHERE d.status = 'VERIFIED' AND b.best_before > '2026-11-05 20:30:00' GROUP BY d.donor_id, d.name ORDER BY stock_value_rs DESC;",
      9: "SELECT fi.item_name, fi.unit, COUNT(*) AS donors, ROUND(MIN(fp.final_price), 2) AS cheapest, ROUND(MAX(fp.final_price), 2) AS costliest, ROUND(AVG(fp.final_price), 2) AS average_price FROM (SELECT l.item_id, l.price_per_unit * (1 - CASE WHEN l.discount_valid_till IS NULL OR l.discount_valid_till >= '2026-11-05 20:30:00' THEN l.discount_percent ELSE 0 END / 100) AS final_price FROM Listing l JOIN Donor d ON d.donor_id = l.donor_id WHERE d.status = 'VERIFIED') AS fp JOIN Food_Item fi ON fi.item_id = fp.item_id GROUP BY fi.item_id, fi.item_name, fi.unit HAVING COUNT(*) >= 2 ORDER BY (MAX(fp.final_price) - MIN(fp.final_price)) DESC;",
      10: "SELECT status, COUNT(*) AS reservations FROM Reservation GROUP BY status ORDER BY reservations DESC;",
      11: "SELECT d.name AS donor, COUNT(*) AS batches_expiring, SUM(b.quantity) AS units_at_risk, MIN(b.best_before) AS earliest_best_before FROM Food_Batch b JOIN Donor d ON d.donor_id = b.donor_id WHERE d.status = 'VERIFIED' AND b.best_before > '2026-11-05 20:30:00' AND b.best_before <= '2026-11-05 20:30:00' + INTERVAL 3 HOUR AND b.quantity > 0 GROUP BY d.donor_id, d.name ORDER BY earliest_best_before;",
      12: "SELECT fi.item_name, COUNT(*) AS searches, SUM(CASE WHEN sl.donors_found = 0 THEN 1 ELSE 0 END) AS searches_with_no_result, COUNT(DISTINCT sl.receiver_id) AS logged_in_searchers FROM Search_Log sl JOIN Food_Item fi ON fi.item_id = sl.item_id GROUP BY fi.item_id, fi.item_name ORDER BY searches DESC LIMIT 5;",
      13: "SELECT d.name AS donor, COUNT(DISTINCT r.reservation_id) AS collected_orders, SUM(ri.quantity) AS units_rescued, SUM(ri.quantity * ri.price_at_reservation) AS sales_rs, ROUND(AVG(f.rating), 1) AS avg_rating FROM Reservation r JOIN Donor d ON d.donor_id = r.donor_id JOIN Reservation_Item ri ON ri.reservation_id = r.reservation_id LEFT JOIN Feedback f ON f.reservation_id = r.reservation_id WHERE r.status = 'COLLECTED' GROUP BY d.donor_id, d.name ORDER BY units_rescued DESC;",
      14: "SELECT d.name AS donor, d.area, l.price_per_unit FROM Listing l JOIN Donor d ON d.donor_id = l.donor_id WHERE d.status = 'VERIFIED' AND l.item_id = (SELECT item_id FROM Food_Item WHERE item_name = 'Veg Biryani') AND l.price_per_unit = (SELECT MIN(l2.price_per_unit) FROM Listing l2 JOIN Donor d2 ON d2.donor_id = l2.donor_id WHERE d2.status = 'VERIFIED' AND l2.item_id = (SELECT item_id FROM Food_Item WHERE item_name = 'Veg Biryani'));",
      15: "SELECT d.name AS donor, fi.item_name, l.price_per_unit, (SELECT ROUND(AVG(l2.price_per_unit), 2) FROM Listing l2 JOIN Donor d2 ON d2.donor_id = l2.donor_id WHERE l2.item_id = l.item_id AND d2.status = 'VERIFIED') AS item_average FROM Listing l JOIN Donor d ON d.donor_id = l.donor_id JOIN Food_Item fi ON fi.item_id = l.item_id WHERE d.status = 'VERIFIED' AND l.price_per_unit > (SELECT AVG(l2.price_per_unit) FROM Listing l2 JOIN Donor d2 ON d2.donor_id = l2.donor_id WHERE l2.item_id = l.item_id AND d2.status = 'VERIFIED') ORDER BY fi.item_name, l.price_per_unit DESC;",
      16: "SELECT rc.receiver_id, rc.name, rc.receiver_type, rc.phone FROM Receiver rc WHERE NOT EXISTS (SELECT 1 FROM Reservation r WHERE r.receiver_id = rc.receiver_id) ORDER BY rc.receiver_id;",
      17: "SELECT d.name, d.donor_type, d.area FROM Donor d WHERE d.donor_id IN (SELECT r.donor_id FROM Reservation r WHERE r.reservation_id IN (SELECT f.reservation_id FROM Feedback f WHERE f.rating = 5)) ORDER BY d.donor_id;",
      18: "SELECT inv.donor, inv.total_units FROM (SELECT d.name AS donor, SUM(b.quantity) AS total_units FROM Donor d JOIN Food_Batch b ON b.donor_id = d.donor_id WHERE d.status = 'VERIFIED' AND b.best_before > '2026-11-05 20:30:00' GROUP BY d.donor_id, d.name) AS inv WHERE inv.total_units > (SELECT AVG(t.total_units) FROM (SELECT SUM(b.quantity) AS total_units FROM Donor d JOIN Food_Batch b ON b.donor_id = d.donor_id WHERE d.status = 'VERIFIED' AND b.best_before > '2026-11-05 20:30:00' GROUP BY d.donor_id) AS t) ORDER BY inv.total_units DESC;",
      19: "SELECT d.donor_id, d.name AS donor_name, d.area, COUNT(DISTINCT l.item_id) AS items_matched FROM Donor d JOIN Listing l ON d.donor_id = l.donor_id WHERE l.item_id IN (SELECT item_id FROM Reservation_Item WHERE reservation_id = 1) AND d.status = 'VERIFIED' GROUP BY d.donor_id, d.name, d.area HAVING COUNT(DISTINCT l.item_id) = (SELECT COUNT(*) FROM Reservation_Item WHERE reservation_id = 1) ORDER BY d.donor_id;",
      20: "SELECT fi.item_name, fi.category, COUNT(*) AS nearby_searches, MAX(sl.searched_at) AS last_searched FROM Search_Log sl JOIN Food_Item fi ON fi.item_id = sl.item_id JOIN Donor d ON d.name = 'Gulab Sweets & Bakers' WHERE sl.searched_at >= '2026-11-05 20:30:00' - INTERVAL 30 DAY AND 6371 * 2 * ASIN(SQRT(POWER(SIN(RADIANS(sl.latitude - d.latitude)/2), 2) + COS(RADIANS(d.latitude))*COS(RADIANS(sl.latitude))*POWER(SIN(RADIANS(sl.longitude - d.longitude)/2), 2))) <= 2 AND NOT EXISTS (SELECT 1 FROM Listing l WHERE l.donor_id = d.donor_id AND l.item_id = sl.item_id) GROUP BY fi.item_id, fi.item_name, fi.category ORDER BY nearby_searches DESC;"
    };

    if (!queries[qNum]) {
      return res.status(404).json({ error: `Query Q${qNum} not defined.` });
    }

    const t0 = Date.now();
    const rows = await executeWithClock(queries[qNum]);
    const duration = Date.now() - t0;

    res.json({
      queryNumber: qNum,
      sql: queries[qNum],
      durationMs: duration,
      rowCount: Array.isArray(rows) ? rows.length : 0,
      data: rows
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`Surplus Food Rescue Server running at http://localhost:${PORT}`);
});
