/**
 * Surplus Food Rescue Frontend Application
 * Interacts with MySQL backend APIs and renders interactive UI
 */

document.addEventListener('DOMContentLoaded', () => {
  // Global State
  let currentTab = 'receiverTab';
  let activeReservation = null;
  let countdownTimer = null;
  let selectedListingForReserve = null;
  let currentQueryNum = 1;

  // Cache DOM Elements
  const navTabs = document.querySelectorAll('.nav-tab');
  const tabContents = document.querySelectorAll('.tab-content');
  const foodGrid = document.getElementById('foodGrid');
  const searchInput = document.getElementById('searchInput');
  const btnSearch = document.getElementById('btnSearch');
  const categoryPills = document.querySelectorAll('#categoryPills .pill');
  const dietPills = document.querySelectorAll('#dietPills .pill');
  
  // Modals
  const reserveModal = document.getElementById('reserveModal');
  const batchModal = document.getElementById('batchModal');
  const rateModal = document.getElementById('rateModal');
  
  // Hold Bar
  const activeHoldBar = document.getElementById('activeHoldBar');
  const holdCountdown = document.getElementById('holdCountdown');
  const holdReservationText = document.getElementById('holdReservationText');
  const btnCancelHold = document.getElementById('btnCancelHold');
  const btnCollectedHold = document.getElementById('btnCollectedHold');

  // Viva Explorer
  const btnQList = document.querySelectorAll('.btn-q');
  const queryTitle = document.getElementById('queryTitle');
  const sqlCodeDisplay = document.getElementById('sqlCodeDisplay');
  const btnRunCurrentQuery = document.getElementById('btnRunCurrentQuery');
  const queryDurationBadge = document.getElementById('queryDurationBadge');
  const resultRowCount = document.getElementById('resultRowCount');
  const vivaResultTable = document.getElementById('vivaResultTable');

  // ==========================================
  // NAVIGATION TABS
  // ==========================================
  navTabs.forEach(tab => {
    tab.addEventListener('click', () => {
      const target = tab.dataset.tab;
      navTabs.forEach(t => t.classList.remove('active'));
      tabContents.forEach(c => c.classList.remove('active'));

      tab.classList.add('active');
      document.getElementById(target).classList.add('active');
      currentTab = target;

      if (target === 'donorTab') loadDonorDashboard();
      if (target === 'adminTab') loadAdminDashboard();
      if (target === 'vivaTab') loadVivaQuery(currentQueryNum);
    });
  });

  // ==========================================
  // TOAST NOTIFICATIONS
  // ==========================================
  function showToast(message, type = 'success') {
    const container = document.getElementById('toastContainer');
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.innerHTML = `<span>${type === 'success' ? '✅' : '⚠️'}</span> <span>${message}</span>`;
    container.appendChild(toast);
    setTimeout(() => {
      toast.style.opacity = '0';
      toast.style.transform = 'translateY(10px)';
      setTimeout(() => toast.remove(), 300);
    }, 4000);
  }

  // ==========================================
  // STATS & KPIS
  // ==========================================
  async function loadStats() {
    try {
      const res = await fetch('/api/stats');
      const data = await res.json();
      if (data && data.verifiedDonors !== undefined) {
        document.getElementById('kpiDonors').innerText = data.verifiedDonors;
        document.getElementById('kpiUnits').innerText = data.totalUnitsAvailable;
        document.getElementById('kpiBatches').innerText = data.activeBatches;
        document.getElementById('kpiRescued').innerText = data.rescuedOrders;
        document.getElementById('kpiHolds').innerText = data.activeHolds;
      }
    } catch (err) {
      console.error("Stats load failed:", err);
    }
  }

  // ==========================================
  // RECEIVER: PUBLIC SURPLUS CATALOG
  // ==========================================
  let selectedCategory = 'ALL';
  let selectedDiet = 'ALL';

  categoryPills.forEach(pill => {
    pill.addEventListener('click', () => {
      categoryPills.forEach(p => p.classList.remove('active'));
      pill.classList.add('active');
      selectedCategory = pill.dataset.cat;
      loadListings();
    });
  });

  dietPills.forEach(pill => {
    pill.addEventListener('click', () => {
      dietPills.forEach(p => p.classList.remove('active'));
      pill.classList.add('active');
      selectedDiet = pill.dataset.diet;
      loadListings();
    });
  });

  btnSearch.addEventListener('click', loadListings);
  searchInput.addEventListener('keyup', (e) => {
    if (e.key === 'Enter') loadListings();
  });

  async function loadListings() {
    foodGrid.innerHTML = '<div class="loading-state">Querying MySQL view `public_listing`...</div>';
    try {
      const search = searchInput.value.trim();
      const url = `/api/public/listings?category=${encodeURIComponent(selectedCategory)}&diet=${encodeURIComponent(selectedDiet)}&search=${encodeURIComponent(search)}`;
      const res = await fetch(url);
      const listings = await res.json();

      if (!Array.isArray(listings) || listings.length === 0) {
        foodGrid.innerHTML = '<div class="loading-state">No surplus food matching your criteria found right now.</div>';
        return;
      }

      foodGrid.innerHTML = listings.map(item => {
        const hasDiscount = parseFloat(item.discount_percent) > 0;
        const isVeg = item.diet_type === 'VEG' || item.diet_type === 'VEGAN';
        return `
          <div class="food-card">
            <div>
              <div class="card-top">
                <div class="item-title-group">
                  <div class="food-item-name">${item.item_name}</div>
                  <div class="food-donor-sub">${item.donor_name} · ${item.area}</div>
                </div>
              </div>

              <div class="food-tags">
                <span class="tag tag-cat">${item.category}</span>
                <span class="tag ${isVeg ? 'tag-diet-veg' : 'tag-diet-nonveg'}">${item.diet_type}</span>
                ${item.available_quantity <= 15 ? '<span class="tag tag-urgency-urgent">🔥 Low Stock</span>' : ''}
              </div>

              <div class="allergen-note">
                <strong>Allergens:</strong> ${item.allergens || 'None declared'}
              </div>
            </div>

            <div>
              <div class="card-pricing-row">
                <div class="price-box">
                  <div class="final-price">₹${parseFloat(item.final_price).toFixed(2)}</div>
                  ${hasDiscount ? `<div class="original-price">₹${parseFloat(item.price_per_unit).toFixed(2)}</div>` : ''}
                  ${hasDiscount ? `<div class="discount-tag">${Math.round(item.discount_percent)}% OFF</div>` : ''}
                </div>
                <div class="stock-indicator">${item.available_quantity} ${item.unit}s left</div>
              </div>

              <div class="card-actions">
                <button class="btn btn-primary btn-block btn-reserve-trigger" data-item='${JSON.stringify(item)}'>
                  Reserve Portion (45m Hold)
                </button>
              </div>
            </div>
          </div>
        `;
      }).join('');

      // Attach reserve button handlers
      document.querySelectorAll('.btn-reserve-trigger').forEach(btn => {
        btn.addEventListener('click', () => {
          const item = JSON.parse(btn.dataset.item);
          openReserveModal(item);
        });
      });

    } catch (err) {
      foodGrid.innerHTML = `<div class="loading-state" style="color: #f87171;">Failed to load listings: ${err.message}</div>`;
    }
  }

  // ==========================================
  // RESERVATION MODAL & ACTIONS
  // ==========================================
  function openReserveModal(item) {
    selectedListingForReserve = item;
    document.getElementById('modalItemName').innerText = item.item_name;
    document.getElementById('modalDonorName').innerText = `${item.donor_name} · ${item.area}`;
    document.getElementById('modalPrice').innerHTML = `₹${parseFloat(item.final_price).toFixed(2)} <span class="text-sm">(Original: ₹${parseFloat(item.price_per_unit).toFixed(2)})</span>`;
    document.getElementById('modalQuantity').value = "2";
    reserveModal.style.display = 'flex';
  }

  document.getElementById('btnCloseReserveModal').addEventListener('click', () => reserveModal.style.display = 'none');
  document.getElementById('btnCancelReserveModal').addEventListener('click', () => reserveModal.style.display = 'none');

  document.getElementById('btnConfirmReserve').addEventListener('click', async () => {
    if (!selectedListingForReserve) return;
    const receiverId = parseInt(document.getElementById('modalReceiverSelect').value);
    const qty = parseInt(document.getElementById('modalQuantity').value) || 1;

    try {
      const res = await fetch('/api/reserve', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          receiver_id: receiverId,
          donor_id: selectedListingForReserve.donor_id,
          items: [{ item_id: selectedListingForReserve.item_id, quantity: qty }]
        })
      });
      const data = await res.json();

      if (!res.ok) {
        throw new Error(data.error || "Reservation failed.");
      }

      reserveModal.style.display = 'none';
      showToast(data.message);

      const reservationId = data.reservation.reservation_id || data.reservation.v_res || 15;
      startActiveHold(reservationId, selectedListingForReserve.donor_name, selectedListingForReserve.item_name, qty);

      // Refresh listings and stats
      loadListings();
      loadStats();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });

  function startActiveHold(resId, donorName, itemName, qty) {
    activeReservation = { id: resId, donorName, itemName, qty, endTime: Date.now() + 45 * 60 * 1000 };
    holdReservationText.innerText = `Hold #${resId}: ${qty}x ${itemName} at ${donorName}`;
    activeHoldBar.style.display = 'flex';

    if (countdownTimer) clearInterval(countdownTimer);
    updateCountdown();
    countdownTimer = setInterval(updateCountdown, 1000);
  }

  function updateCountdown() {
    if (!activeReservation) return;
    const remainingMs = activeReservation.endTime - Date.now();
    if (remainingMs <= 0) {
      clearInterval(countdownTimer);
      holdCountdown.innerText = "EXPIRED (Released to Batch)";
      showToast(`Hold #${activeReservation.id} has expired and was released back to stock.`, 'error');
      activeHoldBar.style.display = 'none';
      activeReservation = null;
      loadListings();
      loadStats();
      return;
    }
    const mins = Math.floor(remainingMs / 60000);
    const secs = Math.floor((remainingMs % 60000) / 1000);
    holdCountdown.innerText = `${mins}:${secs < 10 ? '0' : ''}${secs} remaining`;
  }

  // Cancel Active Hold
  btnCancelHold.addEventListener('click', async () => {
    if (!activeReservation) return;
    if (!confirm(`Cancel hold #${activeReservation.id}? This will immediately return stock to the originating batch.`)) return;

    try {
      const res = await fetch(`/api/reservations/${activeReservation.id}/cancel`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ receiver_id: 1 })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Cancel failed.");

      showToast(data.message);
      clearInterval(countdownTimer);
      activeHoldBar.style.display = 'none';
      activeReservation = null;
      loadListings();
      loadStats();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });

  // Collected & Rate
  btnCollectedHold.addEventListener('click', () => {
    rateModal.style.display = 'flex';
  });

  document.getElementById('btnCloseRateModal').addEventListener('click', () => rateModal.style.display = 'none');
  document.getElementById('btnCancelRateModal').addEventListener('click', () => rateModal.style.display = 'none');

  document.getElementById('btnSubmitFeedback').addEventListener('click', async () => {
    if (!activeReservation) return;
    const rating = parseInt(document.getElementById('rateScoreSelect').value);
    const comment = document.getElementById('rateCommentInput').value.trim();

    try {
      // First collect
      await fetch('/api/donor/collect', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ reservation_id: activeReservation.id, donor_id: 2 })
      });

      // Then rate
      const res = await fetch(`/api/reservations/${activeReservation.id}/rate`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ rating, comment })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Feedback failed.");

      rateModal.style.display = 'none';
      showToast(data.message);
      clearInterval(countdownTimer);
      activeHoldBar.style.display = 'none';
      activeReservation = null;
      loadStats();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });

  // ==========================================
  // DONOR PORTAL
  // ==========================================
  const donorSelect = document.getElementById('donorSelect');
  donorSelect.addEventListener('change', loadDonorDashboard);

  async function loadDonorDashboard() {
    const donorId = donorSelect.value;
    loadExpiringBatches(donorId);
    loadDonorReservations(donorId);
    loadUnmetDemand();
  }

  async function loadExpiringBatches(donorId) {
    const grid = document.getElementById('expiringCardsGrid');
    try {
      const res = await fetch(`/api/donor/expiring?donor_id=${donorId}`);
      const data = await res.json();

      if (!data || data.length === 0) {
        grid.innerHTML = '<div class="text-sm">No batches expiring in the next 3 hours for this donor. All current stock is safely within shelf-life.</div>';
        return;
      }

      grid.innerHTML = data.map(b => `
        <div class="expiring-item-card">
          <div style="display:flex; justify-content:space-between;">
            <strong>${b.item_name}</strong>
            <span class="tag tag-urgency-urgent">${b.urgency}</span>
          </div>
          <div class="text-sm mt-2">Batch: <code>${b.batch_no}</code> · Qty: <strong>${b.quantity}</strong></div>
          <div class="text-sm" style="color: #f59e0b; margin-top: 4px;">⏰ Best before: ${b.best_before} (${b.hours_left}h left)</div>
        </div>
      `).join('');
    } catch (err) {
      grid.innerHTML = `<div class="text-sm" style="color:#f87171;">Failed to load alerts: ${err.message}</div>`;
    }
  }

  async function loadDonorReservations(donorId) {
    const tbody = document.querySelector('#donorReservationsTable tbody');
    tbody.innerHTML = '<tr><td colspan="6" class="text-sm">Loading reservations...</td></tr>';
    try {
      const res = await fetch(`/api/donor/reservations?donor_id=${donorId}`);
      const data = await res.json();

      if (!data || data.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="text-sm">No reservations found for this establishment.</td></tr>';
        return;
      }

      tbody.innerHTML = data.map(r => `
        <tr>
          <td><strong>#${r.reservation_id}</strong></td>
          <td>${r.receiver_name} <span class="badge badge-slate">${r.receiver_type}</span><br><span class="text-sm">${r.phone}</span></td>
          <td>${r.items_summary}</td>
          <td><strong>₹${parseFloat(r.total_amount).toFixed(2)}</strong></td>
          <td><span class="badge ${r.status === 'COLLECTED' ? 'badge-green' : (r.status === 'ACTIVE' ? 'badge-amber' : 'badge-slate')}">${r.status}</span></td>
          <td>
            ${r.status === 'ACTIVE' ? `
              <button class="btn btn-sm btn-success btn-collect" data-id="${r.reservation_id}">Mark Collected</button>
            ` : '<span class="text-sm" style="color:#94a3b8;">Completed</span>'}
          </td>
        </tr>
      `).join('');

      tbody.querySelectorAll('.btn-collect').forEach(btn => {
        btn.addEventListener('click', async () => {
          const resId = btn.dataset.id;
          try {
            const collectRes = await fetch('/api/donor/collect', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ reservation_id: resId, donor_id: donorId })
            });
            const collectData = await collectRes.json();
            if (!collectRes.ok) throw new Error(collectData.error || "Collection failed.");
            showToast(collectData.message);
            loadDonorReservations(donorId);
            loadStats();
          } catch (err) {
            showToast(err.message, 'error');
          }
        });
      });
    } catch (err) {
      tbody.innerHTML = `<tr><td colspan="6" style="color:#f87171;">Failed: ${err.message}</td></tr>`;
    }
  }

  async function loadUnmetDemand() {
    const container = document.getElementById('unmetList');
    try {
      const res = await fetch('/api/donor/unmet-demand');
      const data = await res.json();
      if (!data || data.length === 0) {
        container.innerHTML = '<div class="text-sm">No recorded search gaps nearby.</div>';
        return;
      }
      container.innerHTML = data.slice(0, 5).map(d => `
        <div class="unmet-row">
          <div>
            <strong>${d.item_name}</strong>
            <span class="badge badge-slate" style="margin-left: 6px;">${d.category}</span>
          </div>
          <div style="color: #f59e0b; font-weight: 700; font-size: 13px;">
            ${d.times_searched} searches with 0 results
          </div>
        </div>
      `).join('');
    } catch (err) {
      container.innerHTML = `<div class="text-sm" style="color:#f87171;">Failed: ${err.message}</div>`;
    }
  }

  // Add Batch Modal Handlers
  document.getElementById('btnOpenNewBatchModal').addEventListener('click', () => {
    batchModal.style.display = 'flex';
  });
  document.getElementById('btnCloseBatchModal').addEventListener('click', () => batchModal.style.display = 'none');
  document.getElementById('btnCancelBatchModal').addEventListener('click', () => batchModal.style.display = 'none');

  document.getElementById('btnSubmitBatch').addEventListener('click', async () => {
    const donorId = parseInt(donorSelect.value);
    const itemId = parseInt(document.getElementById('batchItemSelect').value);
    const batchNo = document.getElementById('batchNoInput').value.trim();
    const preparedAt = document.getElementById('preparedAtInput').value.trim();
    const bestBefore = document.getElementById('bestBeforeInput').value.trim();
    const quantity = parseInt(document.getElementById('batchQtyInput').value) || 10;

    try {
      const res = await fetch('/api/donor/batches', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ donor_id: donorId, item_id: itemId, batch_no: batchNo, prepared_at: preparedAt, best_before: bestBefore, quantity })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Batch insertion failed.");

      batchModal.style.display = 'none';
      showToast(data.message);
      loadDonorDashboard();
      loadStats();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });

  // ==========================================
  // ADMIN PORTAL
  // ==========================================
  async function loadAdminDashboard() {
    loadAdminDonors();
    loadAuditLogs();
  }

  async function loadAdminDonors() {
    const tbody = document.querySelector('#adminDonorsTable tbody');
    tbody.innerHTML = '<tr><td colspan="9" class="text-sm">Querying Donor table...</td></tr>';
    try {
      const res = await fetch('/api/admin/donors');
      const donors = await res.json();

      tbody.innerHTML = donors.map(d => `
        <tr>
          <td>#${d.donor_id}</td>
          <td><strong>${d.name}</strong></td>
          <td><span class="badge badge-info">${d.donor_type}</span></td>
          <td><code>${d.fssai_no}</code></td>
          <td>${d.area}</td>
          <td>${d.phone}</td>
          <td>
            <span class="badge ${d.status === 'VERIFIED' ? 'badge-green' : (d.status === 'PENDING' ? 'badge-amber' : 'badge-slate')}">
              ${d.status}
            </span>
          </td>
          <td>${d.reviewed_by || '—'}</td>
          <td>
            ${d.status === 'PENDING' ? `
              <button class="btn btn-sm btn-success btn-verify" data-id="${d.donor_id}">Approve</button>
              <button class="btn btn-sm btn-outline btn-reject" data-id="${d.donor_id}" style="color:#f43f5e;">Reject</button>
            ` : '<span class="text-sm" style="color:#94a3b8;">Locked</span>'}
          </td>
        </tr>
      `).join('');

      tbody.querySelectorAll('.btn-verify').forEach(btn => {
        btn.addEventListener('click', async () => {
          const donorId = btn.dataset.id;
          await updateDonorStatus(donorId, 'VERIFIED');
        });
      });

      tbody.querySelectorAll('.btn-reject').forEach(btn => {
        btn.addEventListener('click', async () => {
          const donorId = btn.dataset.id;
          await updateDonorStatus(donorId, 'REJECTED');
        });
      });

    } catch (err) {
      tbody.innerHTML = `<tr><td colspan="9" style="color:#f87171;">Failed: ${err.message}</td></tr>`;
    }
  }

  async function updateDonorStatus(donorId, status) {
    try {
      const res = await fetch('/api/admin/verify-donor', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ donor_id: donorId, status: status, admin_id: 1 })
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || "Update failed.");
      showToast(data.message);
      loadAdminDonors();
      loadStats();
    } catch (err) {
      showToast(err.message, 'error');
    }
  }

  // Run Expiry Sweep
  document.getElementById('btnRunSweep').addEventListener('click', async () => {
    try {
      const res = await fetch('/api/admin/release-expired', { method: 'POST' });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error);
      showToast(data.message);
      loadAdminDashboard();
      loadStats();
    } catch (err) {
      showToast(err.message, 'error');
    }
  });

  async function loadAuditLogs() {
    const tbody = document.querySelector('#auditLogsTable tbody');
    tbody.innerHTML = '<tr><td colspan="8" class="text-sm">Querying Batch_Log...</td></tr>';
    try {
      const res = await fetch('/api/admin/audit-logs');
      const logs = await res.json();
      tbody.innerHTML = logs.map(l => `
        <tr>
          <td>#${l.log_id}</td>
          <td>${l.donor_name}</td>
          <td><strong>${l.item_name}</strong></td>
          <td><code>${l.batch_no}</code></td>
          <td>${l.old_qty}</td>
          <td><strong>${l.new_qty}</strong></td>
          <td><span class="badge badge-purple">${l.reason}</span></td>
          <td class="text-sm">${l.logged_at}</td>
        </tr>
      `).join('');
    } catch (err) {
      tbody.innerHTML = `<tr><td colspan="8" style="color:#f87171;">Failed: ${err.message}</td></tr>`;
    }
  }

  // ==========================================
  // VIVA QUERY EXPLORER
  // ==========================================
  btnQList.forEach(btn => {
    btn.addEventListener('click', () => {
      btnQList.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      currentQueryNum = parseInt(btn.dataset.q);
      loadVivaQuery(currentQueryNum);
    });
  });

  btnRunCurrentQuery.addEventListener('click', () => {
    loadVivaQuery(currentQueryNum);
  });

  async function loadVivaQuery(qNum) {
    queryTitle.innerText = `Executing Q${qNum} on MySQL...`;
    queryDurationBadge.innerText = "Running...";

    try {
      const res = await fetch(`/api/viva/query/${qNum}`);
      const result = await res.json();

      if (!res.ok) throw new Error(result.error);

      queryTitle.innerText = `Q${result.queryNumber}: Live Execution`;
      sqlCodeDisplay.innerText = result.sql;
      queryDurationBadge.innerText = `Execution: ${result.durationMs} ms (MySQL)`;
      resultRowCount.innerText = `${result.rowCount} rows returned`;

      // Render table
      const thead = vivaResultTable.querySelector('thead');
      const tbody = vivaResultTable.querySelector('tbody');
      thead.innerHTML = '';
      tbody.innerHTML = '';

      if (!result.data || result.data.length === 0) {
        tbody.innerHTML = '<tr><td class="text-sm">Query executed successfully. Zero matching rows.</td></tr>';
        return;
      }

      // Column headers
      const cols = Object.keys(result.data[0]);
      thead.innerHTML = `<tr>${cols.map(c => `<th>${c}</th>`).join('')}</tr>`;

      // Rows
      tbody.innerHTML = result.data.map(row => `
        <tr>${cols.map(c => `<td>${row[c] !== null ? row[c] : '<em style="color:#64748b;">NULL</em>'}</td>`).join('')}</tr>
      `).join('');

    } catch (err) {
      queryTitle.innerText = `Error executing Q${qNum}`;
      queryDurationBadge.innerText = "Failed";
      sqlCodeDisplay.innerText = err.message;
      vivaResultTable.querySelector('tbody').innerHTML = `<tr><td style="color:#f87171;">Execution Error: ${err.message}</td></tr>`;
    }
  }

  // Initial Boot
  loadStats();
  loadListings();
});
