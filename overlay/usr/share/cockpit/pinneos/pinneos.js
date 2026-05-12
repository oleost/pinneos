// ── Utilities ────────────────────────────────────────────────────────────────

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function fmtBytes(n) {
  n = parseInt(n, 10);
  if (isNaN(n) || n < 0) return '—';
  if (n >= 1099511627776) return (n / 1099511627776).toFixed(1) + ' TiB';
  if (n >= 1073741824)    return (n / 1073741824).toFixed(1)    + ' GiB';
  if (n >= 1048576)       return (n / 1048576).toFixed(1)       + ' MiB';
  if (n >= 1024)          return (n / 1024).toFixed(1)           + ' KiB';
  return n + ' B';
}

function showAlert(id, type, msg) {
  var el = document.getElementById(id);
  el.className = 'alert alert-' + type;
  el.textContent = msg;
}

function clearAlert(id) {
  var el = document.getElementById(id);
  el.className = '';
  el.textContent = '';
}

// ── Tabs ─────────────────────────────────────────────────────────────────────

var currentTab = 'setup';

function switchTab(name) {
  ['setup', 'zfs', 'backup', 'access'].forEach(function(t) {
    document.getElementById('pane-' + t).style.display = t === name ? '' : 'none';
    document.getElementById('tab-btn-' + t).classList.toggle('active', t === name);
  });
  currentTab = name;
  if (name === 'zfs')    loadZfs();
  if (name === 'access') updateAccessInfo();
}

// ── Setup tab ─────────────────────────────────────────────────────────────────

function updateHostnamePreview() {
  var v = document.getElementById('hostname-input').value.trim() || 'pinneos';
  document.getElementById('hostname-preview').textContent = 'http://' + v + '.local';
}

function loadHostname() {
  cockpit.file('/etc/hostname').read().then(function(content) {
    if (content) {
      document.getElementById('hostname-input').value = content.trim();
      updateHostnamePreview();
    }
  });
}

function saveHostname() {
  var name = document.getElementById('hostname-input').value.trim();
  if (!name || !/^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$/.test(name)) {
    showAlert('hostname-alert', 'danger', 'Invalid hostname. Use letters, digits and hyphens.');
    return;
  }
  cockpit.spawn(['/usr/bin/hostnamectl', 'set-hostname', name], {superuser: 'try'})
    .then(function() {
      showAlert('hostname-alert', 'success', 'Hostname set to "' + name + '".');
    })
    .catch(function(err) {
      showAlert('hostname-alert', 'danger', String(err.message || err));
    });
}

function savePassword() {
  var pw1 = document.getElementById('pw1').value;
  var pw2 = document.getElementById('pw2').value;
  if (pw1.length < 8) {
    showAlert('password-alert', 'warning', 'Password must be at least 8 characters.');
    return;
  }
  if (pw1 !== pw2) {
    showAlert('password-alert', 'warning', 'Passwords do not match.');
    return;
  }
  cockpit.spawn(['/usr/bin/chpasswd'], {superuser: 'try', err: 'message'})
    .input('root:' + pw1 + '\n')
    .then(function() {
      document.getElementById('pw1').value = '';
      document.getElementById('pw2').value = '';
      showAlert('password-alert', 'success', 'Password changed.');
    })
    .catch(function(err) {
      showAlert('password-alert', 'danger', String(err.message || err));
    });
}

// ── Access tab ────────────────────────────────────────────────────────────────

function updateAccessInfo() {
  cockpit.spawn(['/usr/bin/ip', '-4', 'addr', 'show', 'scope', 'global'])
    .then(function(output) {
      var ip = '';
      output.split('\n').forEach(function(line) {
        if (!ip && line.indexOf('inet ') !== -1 && line.indexOf('docker') === -1) {
          var m = line.trim().match(/inet (\d+\.\d+\.\d+\.\d+)/);
          if (m) ip = m[1];
        }
      });
      if (!ip) { document.getElementById('info-ip').textContent = 'Not detected'; return; }
      document.getElementById('info-ip').textContent = ip;
      function link(url) { return '<a href="' + url + '" target="_blank">' + url + '</a>'; }
      document.getElementById('info-cockpit').innerHTML  = link('http://' + ip + ':9090');
      document.getElementById('info-dockge').innerHTML   = link('http://' + ip + ':5001');
      document.getElementById('info-homepage').innerHTML = link('http://' + ip);
    })
    .catch(function() {
      document.getElementById('info-ip').textContent = 'Not detected';
    });
  checkZfsPool();
}

function checkZfsPool() {
  cockpit.spawn(['/usr/bin/zpool', 'list', '-H', '-o', 'name'], {err: 'message'})
    .then(function(output) {
      var pools = output.trim().split('\n').filter(Boolean);
      document.getElementById('info-pool').textContent =
        pools.length ? pools.join(', ') : 'None';
    })
    .catch(function() {
      document.getElementById('info-pool').textContent = 'None';
    });
}

// ── ZFS tab ───────────────────────────────────────────────────────────────────

function loadZfs() {
  loadPools();
  loadDisks();
}

// -- Pools --------------------------------------------------------------------

function loadPools() {
  cockpit.spawn(['/usr/bin/zpool', 'list', '-H', '-p', '-o', 'name,size,alloc,free,health'], {err: 'message'})
    .then(function(output) {
      var pools = output.trim().split('\n').filter(Boolean).map(function(line) {
        var f = line.split('\t');
        return {name: f[0], size: f[1], alloc: f[2], free: f[3], health: f[4]};
      });
      renderPoolTable(pools);
      updateDatasetPoolSelect(pools.map(function(p) { return p.name; }));
    })
    .catch(function() {
      renderPoolTable([]);
      updateDatasetPoolSelect([]);
    });
}

function renderPoolTable(pools) {
  var wrap = document.getElementById('pool-table-wrap');
  if (!pools.length) {
    wrap.innerHTML = '<p class="empty-text">No ZFS pools. Create one above.</p>';
    return;
  }
  var html = '<table><thead><tr>' +
    '<th>Name</th><th>Size</th><th>Used</th><th>Free</th><th>Health</th><th></th>' +
    '</tr></thead><tbody>';
  pools.forEach(function(p) {
    var hc = p.health === 'ONLINE' ? 'badge-ok' : 'badge-warn';
    html += '<tr>' +
      '<td><strong>' + esc(p.name) + '</strong></td>' +
      '<td>' + fmtBytes(p.size) + '</td>' +
      '<td>' + fmtBytes(p.alloc) + '</td>' +
      '<td>' + fmtBytes(p.free) + '</td>' +
      '<td><span class="badge ' + hc + '">' + esc(p.health) + '</span></td>' +
      '<td><button class="btn btn-danger-sm" data-action="destroy-pool" data-name="' + esc(p.name) + '">Destroy</button></td>' +
      '</tr>';
  });
  html += '</tbody></table>';
  wrap.innerHTML = html;
}

function updateDatasetPoolSelect(poolNames) {
  var sel = document.getElementById('dataset-pool-select');
  var prev = sel.value;
  sel.innerHTML = poolNames.length
    ? poolNames.map(function(n) { return '<option value="' + esc(n) + '">' + esc(n) + '</option>'; }).join('')
    : '<option value="">— no pools —</option>';
  if (poolNames.indexOf(prev) !== -1) sel.value = prev;
  if (poolNames.length) loadDatasets(sel.value);
  else document.getElementById('dataset-table-wrap').innerHTML = '<p class="empty-text">No pools found.</p>';
}

// -- Disk picker --------------------------------------------------------------

var availableDisks = [];

function loadDisks() {
  cockpit.spawn(['/usr/bin/lsblk', '-J', '-b', '-o', 'NAME,SIZE,TYPE,MODEL,ROTA,MOUNTPOINTS'], {err: 'message'})
    .then(function(output) {
      var data = JSON.parse(output);
      cockpit.spawn(['/usr/bin/zpool', 'status'], {err: 'message'})
        .then(function(zpoolOut) {
          var zdevs = new Set();
          zpoolOut.split('\n').forEach(function(line) {
            var tok = line.trim().split(/\s+/)[0];
            if (tok && tok.startsWith('/dev/')) zdevs.add(tok);
          });
          availableDisks = (data.blockdevices || []).filter(function(d) {
            return d.type === 'disk' && !zdevs.has('/dev/' + d.name);
          });
          renderDiskList();
        })
        .catch(function() {
          availableDisks = (data.blockdevices || []).filter(function(d) { return d.type === 'disk'; });
          renderDiskList();
        });
    })
    .catch(function(err) {
      document.getElementById('disk-list').innerHTML = '<span class="empty-text">Could not list disks: ' + esc(String(err.message || err)) + '</span>';
    });
}

function renderDiskList() {
  var el = document.getElementById('disk-list');
  if (!availableDisks.length) {
    el.innerHTML = '<span class="empty-text">No unused disks found.</span>';
    return;
  }
  el.innerHTML = availableDisks.map(function(d) {
    var model = (d.model || 'Unknown').trim();
    var size  = fmtBytes(d.size);
    var type  = d.rota ? 'HDD' : 'SSD';
    return '<label class="disk-item">' +
      '<input type="checkbox" name="disk" value="/dev/' + esc(d.name) + '"> ' +
      '<span class="disk-name">/dev/' + esc(d.name) + '</span> ' +
      '<span class="disk-meta">' + esc(model) + ' &mdash; ' + size + ' &mdash; ' + type + '</span>' +
      '</label>';
  }).join('');
}

function selectedDisks() {
  return Array.from(document.querySelectorAll('#disk-list input[name=disk]:checked'))
    .map(function(cb) { return cb.value; });
}

// -- Create pool --------------------------------------------------------------

function createPool() {
  clearAlert('create-pool-alert');
  var name  = document.getElementById('pool-name').value.trim();
  var topo  = document.getElementById('pool-topology').value;
  var disks = selectedDisks();

  if (!name || !/^[a-zA-Z][a-zA-Z0-9_-]*$/.test(name)) {
    showAlert('create-pool-alert', 'danger', 'Invalid pool name. Use letters, digits, _ or -.');
    return;
  }
  if (!disks.length) {
    showAlert('create-pool-alert', 'danger', 'Select at least one disk.');
    return;
  }
  var minDisks = {stripe: 1, mirror: 2, raidz: 3, raidz2: 4, raidz3: 5};
  if (disks.length < minDisks[topo]) {
    showAlert('create-pool-alert', 'danger',
      topo + ' requires at least ' + minDisks[topo] + ' disks. You selected ' + disks.length + '.');
    return;
  }

  var cmd = ['/usr/bin/zpool', 'create', '-f', name];
  if (topo !== 'stripe') cmd.push(topo);
  cmd = cmd.concat(disks);

  showAlert('create-pool-alert', 'warning', 'Creating pool…');
  cockpit.spawn(cmd, {superuser: 'try', err: 'message'})
    .then(function() {
      return initPool(name);
    })
    .then(function() {
      showAlert('create-pool-alert', 'success', 'Pool "' + name + '" created with standard datasets.');
      document.getElementById('pool-name').value = '';
      document.getElementById('create-pool-form').style.display = 'none';
      loadPools();
      loadDisks();
    })
    .catch(function(err) {
      showAlert('create-pool-alert', 'danger', String(err.message || err));
    });
}

function initPool(name) {
  var cmds = [
    ['/usr/bin/zfs', 'set', 'pinneos:managed=yes', name],
    ['/usr/bin/zfs', 'create', name + '/system'],
    ['/usr/bin/zfs', 'create', '-o', 'xattr=sa', '-o', 'acltype=posixacl', name + '/apps'],
    ['/usr/bin/zfs', 'create', name + '/storage'],
    ['/usr/bin/zfs', 'create', name + '/storage/media'],
    ['/usr/bin/zfs', 'create', name + '/storage/backups'],
    ['/usr/bin/zfs', 'create', name + '/storage/shared'],
  ];
  return cmds.reduce(function(chain, cmd) {
    return chain.then(function() {
      return cockpit.spawn(cmd, {superuser: 'try', err: 'message'});
    });
  }, Promise.resolve());
}

function confirmDestroyPool(name) {
  if (!window.confirm('Permanently destroy pool "' + name + '" and ALL data on it?')) return;
  cockpit.spawn(['/usr/bin/zpool', 'destroy', name], {superuser: 'try', err: 'message'})
    .then(function() { loadPools(); loadDisks(); })
    .catch(function(err) {
      document.getElementById('pool-table-wrap').insertAdjacentHTML(
        'beforeend', '<p class="alert alert-danger" style="margin-top:8px">' + esc(String(err.message || err)) + '</p>'
      );
    });
}

// -- Datasets -----------------------------------------------------------------

function loadDatasets(pool) {
  if (!pool) return;
  cockpit.spawn(['/usr/bin/zfs', 'list', '-H', '-p', '-r', '-o', 'name,used,avail,mountpoint,type', pool], {err: 'message'})
    .then(function(output) {
      var rows = output.trim().split('\n').filter(Boolean).map(function(line) {
        var f = line.split('\t');
        return {name: f[0], used: f[1], avail: f[2], mount: f[3], type: f[4]};
      });
      renderDatasetTable(rows);
    })
    .catch(function(err) {
      document.getElementById('dataset-table-wrap').innerHTML =
        '<p class="empty-text">' + esc(String(err.message || err)) + '</p>';
    });
}

function renderDatasetTable(rows) {
  var wrap = document.getElementById('dataset-table-wrap');
  if (!rows.length) {
    wrap.innerHTML = '<p class="empty-text">No datasets.</p>';
    return;
  }
  var html = '<table><thead><tr>' +
    '<th>Name</th><th>Used</th><th>Available</th><th>Mountpoint</th><th>Type</th><th></th>' +
    '</tr></thead><tbody>';
  rows.forEach(function(r) {
    var isPool = r.name === r.name.replace(/\/.*/, '');
    html += '<tr>' +
      '<td>' + esc(r.name) + '</td>' +
      '<td>' + fmtBytes(r.used) + '</td>' +
      '<td>' + fmtBytes(r.avail) + '</td>' +
      '<td>' + esc(r.mount) + '</td>' +
      '<td>' + esc(r.type) + '</td>' +
      '<td>' + (isPool ? '' :
        '<button class="btn btn-danger-sm" data-action="destroy-dataset" data-name="' + esc(r.name) + '">Destroy</button>'
      ) + '</td>' +
      '</tr>';
  });
  html += '</tbody></table>';
  wrap.innerHTML = html;
}

function createDataset() {
  clearAlert('create-dataset-alert');
  var pool   = document.getElementById('dataset-pool-select').value;
  var dsname = document.getElementById('dataset-name').value.trim();
  if (!pool) { showAlert('create-dataset-alert', 'danger', 'No pool selected.'); return; }
  if (!dsname || !/^[a-zA-Z][a-zA-Z0-9/_-]*$/.test(dsname)) {
    showAlert('create-dataset-alert', 'danger', 'Invalid dataset name.');
    return;
  }
  var full = pool + '/' + dsname;
  cockpit.spawn(['/usr/bin/zfs', 'create', full], {superuser: 'try', err: 'message'})
    .then(function() {
      document.getElementById('dataset-name').value = '';
      document.getElementById('create-dataset-form').style.display = 'none';
      loadDatasets(pool);
    })
    .catch(function(err) {
      showAlert('create-dataset-alert', 'danger', String(err.message || err));
    });
}

function confirmDestroyDataset(name) {
  if (!window.confirm('Permanently destroy dataset "' + name + '" and all data in it?')) return;
  cockpit.spawn(['/usr/bin/zfs', 'destroy', '-r', name], {superuser: 'try', err: 'message'})
    .then(function() {
      var pool = document.getElementById('dataset-pool-select').value;
      loadDatasets(pool);
    })
    .catch(function(err) {
      document.getElementById('dataset-table-wrap').insertAdjacentHTML(
        'beforeend', '<p class="alert alert-danger" style="margin-top:8px">' + esc(String(err.message || err)) + '</p>'
      );
    });
}

// ── Event delegation for dynamic table buttons ────────────────────────────────

document.getElementById('pool-table-wrap').addEventListener('click', function(e) {
  var btn = e.target.closest('[data-action]');
  if (!btn) return;
  if (btn.dataset.action === 'destroy-pool') confirmDestroyPool(btn.dataset.name);
});

document.getElementById('dataset-table-wrap').addEventListener('click', function(e) {
  var btn = e.target.closest('[data-action]');
  if (!btn) return;
  if (btn.dataset.action === 'destroy-dataset') confirmDestroyDataset(btn.dataset.name);
});

// ── Backup tab ────────────────────────────────────────────────────────────────

function radioValue(name) {
  var el = document.querySelector('input[name="' + name + '"]:checked');
  return el ? el.value : '';
}

function appendLog(id, text) {
  var el = document.getElementById(id);
  el.style.display = '';
  el.textContent += text;
  el.scrollTop = el.scrollHeight;
}

function clearLog(id) {
  var el = document.getElementById(id);
  el.textContent = '';
  el.style.display = 'none';
}

function runBackup() {
  var dest = document.getElementById('backup-dest').value.trim();
  var mode = radioValue('backup-mode');
  if (!dest) { alert('Enter a destination pool or dataset.'); return; }
  clearLog('backup-log');
  appendLog('backup-log', 'Starting backup...\n');
  document.getElementById('btn-run-backup').disabled = true;
  cockpit.spawn(
    ['/usr/lib/homelab/backup.sh', 'create', '--dest', dest, '--mode', mode],
    {superuser: 'try', err: 'message'}
  )
  .stream(function(data) { appendLog('backup-log', data); })
  .then(function() {
    appendLog('backup-log', '\n✓ Backup complete.');
  })
  .catch(function(err) {
    appendLog('backup-log', '\n✗ Error: ' + String(err.message || err));
  })
  .finally(function() {
    document.getElementById('btn-run-backup').disabled = false;
  });
}

function listBackups() {
  var dest = document.getElementById('backup-list-dest').value.trim();
  if (!dest) { alert('Enter a destination pool or dataset.'); return; }
  var wrap = document.getElementById('backup-list-wrap');
  wrap.innerHTML = '<p class="empty-text">Loading…</p>';
  cockpit.spawn(
    ['/usr/lib/homelab/backup.sh', 'list', '--dest', dest],
    {superuser: 'try', err: 'message'}
  )
  .then(function(output) {
    if (!output.trim()) {
      wrap.innerHTML = '<p class="empty-text">No backups found at "' + esc(dest) + '".</p>';
      return;
    }
    wrap.innerHTML = '<pre class="output-pre">' + esc(output) + '</pre>';
  })
  .catch(function(err) {
    wrap.innerHTML = '<p class="alert alert-danger">' + esc(String(err.message || err)) + '</p>';
  });
}

function runRestore() {
  var source   = document.getElementById('restore-source').value.trim();
  var snapshot = document.getElementById('restore-snapshot').value.trim();
  var dest     = document.getElementById('restore-dest').value.trim();
  var mode     = radioValue('restore-mode');
  if (!source) { alert('Enter a source pool or dataset.'); return; }
  if (!dest)   { alert('Enter a destination pool.'); return; }
  if (!confirm('Restore will overwrite existing datasets on "' + dest + '". Continue?')) return;

  clearLog('restore-log');
  appendLog('restore-log', 'Starting restore...\n');
  document.getElementById('btn-run-restore').disabled = true;

  var cmd = ['/usr/lib/homelab/restore.sh', 'run',
    '--source', source, '--dest', dest, '--mode', mode];
  if (snapshot) cmd = cmd.concat(['--snapshot', snapshot]);

  cockpit.spawn(cmd, {superuser: 'try', err: 'message'})
  .stream(function(data) { appendLog('restore-log', data); })
  .then(function() {
    appendLog('restore-log', '\n✓ Restore complete. Reboot to apply.');
  })
  .catch(function(err) {
    appendLog('restore-log', '\n✗ Error: ' + String(err.message || err));
  })
  .finally(function() {
    document.getElementById('btn-run-restore').disabled = false;
  });
}

// ── Backup USB (Setup tab) ────────────────────────────────────────────────────

var BACKUP_UUID_FILE = '/etc/homelab/backup-usb-uuid';

function loadBackupUsb() {
  cockpit.spawn(['/usr/bin/cat', BACKUP_UUID_FILE], {err: 'message'})
    .then(function(content) {
      renderBackupUsbRegistered((content || '').trim());
    })
    .catch(function() {
      renderBackupUsbRegistered('');
    });
  scanBackupUsbCandidates();
}

function renderBackupUsbRegistered(uuid) {
  var el = document.getElementById('backup-usb-registered');
  if (uuid) {
    el.innerHTML =
      '<div class="alert alert-success" style="display:flex;justify-content:space-between;align-items:center;gap:8px">' +
        '<span><strong>Registered</strong> — UUID: <code>' + esc(uuid) + '</code></span>' +
        '<div style="display:flex;gap:6px;flex-shrink:0">' +
          '<button class="btn btn-primary" id="btn-sync-backup-usb">Sync now</button>' +
          '<button class="btn btn-danger-sm" id="btn-unregister-backup-usb">Remove</button>' +
        '</div>' +
      '</div>';
    document.getElementById('btn-sync-backup-usb').addEventListener('click', syncBackupUsbNow);
    document.getElementById('btn-unregister-backup-usb').addEventListener('click', unregisterBackupUsb);
  } else {
    el.innerHTML = '<p class="hint">No backup USB registered.</p>';
  }
}

function scanBackupUsbCandidates() {
  var wrap = document.getElementById('backup-usb-candidates');
  wrap.innerHTML = '<p class="empty-text">Scanning for PinneOS USB sticks…</p>';
  findBootDisk()
    .then(function(bootDisk) { return findBackupCandidates(bootDisk); })
    .then(function(candidates) { renderBackupUsbCandidates(candidates); })
    .catch(function() { renderBackupUsbCandidates([]); });
}

function findBootDisk() {
  function diskOf(label) {
    return cockpit.spawn(['/usr/bin/findfs', 'LABEL=' + label], {err: 'message'})
      .then(function(part) {
        return cockpit.spawn(['/usr/bin/lsblk', '-no', 'PKNAME', part.trim()], {err: 'message'});
      })
      .then(function(out) { return '/dev/' + out.trim(); });
  }
  return diskOf('PINNEOS_A')
    .catch(function() { return diskOf('PINNEOS_B'); })
    .catch(function() { return ''; });
}

function findBackupCandidates(bootDisk) {
  return cockpit.spawn(
    ['/usr/bin/lsblk', '-J', '-b', '-o', 'NAME,SIZE,MODEL,TYPE,LABEL,UUID'],
    {err: 'message'}
  ).then(function(output) {
    var data = JSON.parse(output);
    var candidates = [];
    (data.blockdevices || []).forEach(function(dev) {
      if (dev.type !== 'disk') return;
      var disk = '/dev/' + dev.name;
      if (disk === bootDisk) return;
      (dev.children || []).forEach(function(child) {
        if (child.label === 'PINNEOS_A' && child.uuid) {
          candidates.push({
            disk:  disk,
            uuid:  child.uuid,
            model: (dev.model || 'Unknown').trim(),
            size:  dev.size,
          });
        }
      });
    });
    return candidates;
  });
}

function renderBackupUsbCandidates(candidates) {
  var wrap = document.getElementById('backup-usb-candidates');
  if (!candidates.length) {
    wrap.innerHTML =
      '<p class="hint">No other PinneOS USB detected. ' +
      'Write the .img to a second USB with Etcher, plug it in, then click ↻ Refresh.</p>';
    return;
  }
  var html = '<p style="margin:0 0 8px;font-weight:600">Detected PinneOS USBs:</p>';
  candidates.forEach(function(c) {
    html += '<div class="disk-item" style="justify-content:space-between">' +
      '<div>' +
        '<span class="disk-name">' + esc(c.disk) + '</span> ' +
        '<span class="disk-meta">' + esc(c.model) + ' — ' + fmtBytes(c.size) + '</span>' +
      '</div>' +
      '<button class="btn btn-primary" data-action="register-backup" ' +
        'data-uuid="' + esc(c.uuid) + '">Register</button>' +
      '</div>';
  });
  wrap.innerHTML = html;
}

function registerBackupUsb(uuid) {
  cockpit.spawn(['/usr/bin/bash', '-c', 'echo ' + uuid + ' > ' + BACKUP_UUID_FILE],
    {superuser: 'try', err: 'message'})
    .then(function() {
      showAlert('backup-usb-alert', 'success', 'Backup USB registered.');
      loadBackupUsb();
    })
    .catch(function(err) {
      showAlert('backup-usb-alert', 'danger', String(err.message || err));
    });
}

function unregisterBackupUsb() {
  if (!window.confirm('Remove backup USB registration?')) return;
  cockpit.spawn(['/usr/bin/rm', '-f', BACKUP_UUID_FILE], {superuser: 'try', err: 'message'})
    .then(function() {
      showAlert('backup-usb-alert', 'success', 'Registration removed.');
      loadBackupUsb();
    })
    .catch(function(err) {
      showAlert('backup-usb-alert', 'danger', String(err.message || err));
    });
}

function syncBackupUsbNow() {
  var logEl = document.getElementById('backup-usb-sync-log');
  logEl.style.display = '';
  logEl.textContent = 'Syncing backup USB…\n';
  document.getElementById('btn-sync-backup-usb').disabled = true;
  cockpit.spawn(['/usr/lib/homelab/backup-usb-sync.sh'], {superuser: 'try', err: 'message'})
    .stream(function(data) { logEl.textContent += data; logEl.scrollTop = logEl.scrollHeight; })
    .then(function() { logEl.textContent += '\n✓ Sync complete.'; })
    .catch(function(err) { logEl.textContent += '\n✗ Error: ' + String(err.message || err); })
    .finally(function() {
      document.getElementById('btn-sync-backup-usb').disabled = false;
    });
}

// ── Wire up static controls ───────────────────────────────────────────────────

document.getElementById('tab-btn-setup').addEventListener('click',   function() { switchTab('setup');  });
document.getElementById('tab-btn-zfs').addEventListener('click',     function() { switchTab('zfs');    });
document.getElementById('tab-btn-backup').addEventListener('click',  function() { switchTab('backup'); });
document.getElementById('tab-btn-access').addEventListener('click',  function() { switchTab('access'); });

document.getElementById('btn-run-backup').addEventListener('click', runBackup);
document.getElementById('btn-list-backups').addEventListener('click', listBackups);
document.getElementById('btn-run-restore').addEventListener('click', runRestore);

document.getElementById('hostname-input').addEventListener('input', updateHostnamePreview);
document.getElementById('btn-save-hostname').addEventListener('click', saveHostname);
document.getElementById('btn-save-password').addEventListener('click', savePassword);

document.getElementById('btn-show-create-pool').addEventListener('click', function() {
  document.getElementById('create-pool-form').style.display = '';
  clearAlert('create-pool-alert');
});
document.getElementById('btn-cancel-create-pool').addEventListener('click', function() {
  document.getElementById('create-pool-form').style.display = 'none';
});
document.getElementById('btn-create-pool').addEventListener('click', createPool);

document.getElementById('btn-show-create-dataset').addEventListener('click', function() {
  document.getElementById('create-dataset-form').style.display = '';
  clearAlert('create-dataset-alert');
});
document.getElementById('btn-cancel-create-dataset').addEventListener('click', function() {
  document.getElementById('create-dataset-form').style.display = 'none';
});
document.getElementById('btn-create-dataset').addEventListener('click', createDataset);

document.getElementById('dataset-pool-select').addEventListener('change', function() {
  loadDatasets(this.value);
});

document.getElementById('backup-usb-candidates').addEventListener('click', function(e) {
  var btn = e.target.closest('[data-action]');
  if (!btn) return;
  if (btn.dataset.action === 'register-backup') registerBackupUsb(btn.dataset.uuid);
});

document.getElementById('btn-refresh-backup-usb').addEventListener('click', function() {
  clearAlert('backup-usb-alert');
  loadBackupUsb();
});

// ── Init ──────────────────────────────────────────────────────────────────────

switchTab('setup');
loadHostname();
loadBackupUsb();
