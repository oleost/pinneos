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
  ['setup', 'zfs', 'backup', 'access', 'update'].forEach(function(t) {
    document.getElementById('pane-' + t).style.display = t === name ? '' : 'none';
    document.getElementById('tab-btn-' + t).classList.toggle('active', t === name);
  });
  currentTab = name;
  if (name === 'zfs')    loadZfs();
  if (name === 'access') updateAccessInfo();
  if (name === 'update') loadUpdateTab();
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
  document.getElementById('create-pool-form').style.display = 'none';
  document.getElementById('encrypt-pool').checked = false;
  document.getElementById('encrypt-fields').style.display = 'none';
  clearAlert('create-pool-alert');
  loadPools();
  loadDisks();
  checkUnlockStatus();
}

// -- Pools --------------------------------------------------------------------

function loadPools() {
  cockpit.spawn(['/usr/bin/zpool', 'list', '-H', '-p', '-o', 'name,size,alloc,free,health'], {err: 'message'})
    .then(function(output) {
      var pools = output.trim().split('\n').filter(Boolean).map(function(line) {
        var f = line.split('\t');
        return {name: f[0], size: f[1], alloc: f[2], free: f[3], health: f[4],
                encryption: 'off', keystatus: '-'};
      });

      if (!pools.length) {
        renderPoolTable([]);
        updateDatasetPoolSelect([]);
        renderEncryptionCard([]);
        loadPoolHealth([]);
        return;
      }

      var poolNames = pools.map(function(p) { return p.name; });
      updateDatasetPoolSelect(poolNames);
      loadPoolHealth(poolNames);

      cockpit.spawn(
        ['/usr/bin/zfs', 'get', '-H', '-o', 'name,property,value',
          'encryption,keystatus'].concat(poolNames),
        {err: 'message'}
      )
      .then(function(encOut) {
        var encMap = {};
        encOut.trim().split('\n').filter(Boolean).forEach(function(line) {
          var p = line.split('\t');
          if (!encMap[p[0]]) encMap[p[0]] = {};
          encMap[p[0]][p[1]] = p[2];
        });
        pools.forEach(function(p) {
          if (encMap[p.name]) {
            p.encryption = encMap[p.name].encryption || 'off';
            p.keystatus  = encMap[p.name].keystatus  || '-';
          }
        });
        renderPoolTable(pools);
        renderEncryptionCard(pools.filter(function(p) {
          return p.encryption !== 'off' && p.encryption !== '-';
        }));
      })
      .catch(function() {
        renderPoolTable(pools);
        renderEncryptionCard([]);
        loadPoolHealth(poolNames);
      });
    })
    .catch(function() {
      renderPoolTable([]);
      updateDatasetPoolSelect([]);
      renderEncryptionCard([]);
      loadPoolHealth([]);
    });
}

function renderPoolTable(pools) {
  var wrap = document.getElementById('pool-table-wrap');
  if (!pools.length) {
    wrap.innerHTML = '<p class="empty-text">No ZFS pools. Create one above.</p>';
    return;
  }
  var html = '<table><thead><tr>' +
    '<th>Name</th><th>Size</th><th>Used</th><th>Free</th><th>Health</th><th>Encryption</th><th></th>' +
    '</tr></thead><tbody>';
  pools.forEach(function(p) {
    var hc  = p.health === 'ONLINE' ? 'badge-ok' : 'badge-warn';
    var enc = '<span style="color:#6a6e73;font-size:12px">Off</span>';
    if (p.encryption && p.encryption !== 'off' && p.encryption !== '-') {
      enc = p.keystatus === 'available'
        ? '<span class="badge badge-ok">Unlocked</span>'
        : '<span class="badge badge-lock">Locked</span>';
    }
    html += '<tr>' +
      '<td><strong>' + esc(p.name) + '</strong></td>' +
      '<td>' + fmtBytes(p.size) + '</td>' +
      '<td>' + fmtBytes(p.alloc) + '</td>' +
      '<td>' + fmtBytes(p.free) + '</td>' +
      '<td><span class="badge ' + hc + '">' + esc(p.health) + '</span></td>' +
      '<td>' + enc + '</td>' +
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

  if (document.getElementById('encrypt-pool').checked) {
    var pass1 = document.getElementById('encrypt-pass1').value;
    var pass2 = document.getElementById('encrypt-pass2').value;
    if (pass1.length < 12) {
      showAlert('create-pool-alert', 'danger', 'Passphrase must be at least 12 characters.');
      return;
    }
    if (pass1 !== pass2) {
      showAlert('create-pool-alert', 'danger', 'Passphrases do not match.');
      return;
    }
    var saveToUsb = document.getElementById('encrypt-save-usb').checked ? 'true' : 'false';
    createEncryptedPool(name, topo, disks, pass1, saveToUsb);
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

function createEncryptedPool(name, topo, disks, passphrase, saveToUsb) {
  showAlert('create-pool-alert', 'warning', 'Creating encrypted pool — this may take a moment…');

  var args = ['/usr/lib/homelab/zfs-encrypt.sh', 'create-pool', name];
  if (topo !== 'stripe') args.push(topo);
  args = args.concat(disks);

  cockpit.spawn(args, {superuser: 'require', err: 'message'})
    .input(passphrase + '\n' + saveToUsb + '\n')
    .then(function(output) {
      var m = output.match(/RECOVERY_KEY:([0-9a-f]{64})/);
      var recoveryHex = m ? m[1] : null;
      return initPool(name).then(function() { return recoveryHex; });
    })
    .then(function(recoveryHex) {
      document.getElementById('pool-name').value = '';
      document.getElementById('encrypt-pass1').value = '';
      document.getElementById('encrypt-pass2').value = '';
      document.getElementById('encrypt-pool').checked = false;
      document.getElementById('encrypt-fields').style.display = 'none';
      document.getElementById('create-pool-form').style.display = 'none';
      clearAlert('create-pool-alert');
      loadPools();
      loadDisks();
      if (recoveryHex) showRecoveryKeyModal(name, recoveryHex);
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
        'beforeend',
        '<p class="alert alert-danger" style="margin-top:8px">' +
          esc(String(err.message || err)) +
          ' — Try <strong>Release mounts</strong> first to stop Docker.' +
        '</p>'
      );
    });
}

function releaseDockerMounts() {
  if (!window.confirm(
    'This will stop Docker (all containers go down) and unmount /var/lib/docker.\n\n' +
    'Do this only when you want to destroy a pool and start fresh.'
  )) return;

  var alertEl = document.getElementById('release-mounts-alert');
  showAlert('release-mounts-alert', 'warning', 'Stopping Docker…');
  document.getElementById('btn-release-mounts').disabled = true;

  cockpit.spawn(
    ['/usr/bin/systemctl', 'stop', 'docker', 'docker.socket'],
    {superuser: 'require', err: 'message'}
  )
  .then(function() {
    showAlert('release-mounts-alert', 'warning', 'Unmounting /var/lib/docker…');
    return cockpit.spawn(
      ['/usr/bin/umount', '/var/lib/docker'],
      {superuser: 'require', err: 'message'}
    );
  })
  .then(function() {
    showAlert('release-mounts-alert', 'success',
      'Docker stopped and mounts released. You can now destroy pools. ' +
      'Reboot or create a new pool to restart Docker.');
    loadPools();
  })
  .catch(function(err) {
    var msg = String(err.message || err);
    // umount fails with "not mounted" if Docker was already on tmpfs — that's fine
    if (msg.indexOf('not mounted') !== -1 || msg.indexOf('no mount point') !== -1) {
      showAlert('release-mounts-alert', 'success',
        'Docker stopped. No ZFS bind-mount was active — pools can be destroyed.');
      loadPools();
    } else {
      showAlert('release-mounts-alert', 'danger', msg);
      document.getElementById('btn-release-mounts').disabled = false;
    }
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

// ── Pool health ───────────────────────────────────────────────────────────────

function loadPoolHealth(poolNames) {
  var card = document.getElementById('card-pool-health');
  if (!poolNames.length) { card.style.display = 'none'; return; }
  card.style.display = '';

  var wrap = document.getElementById('pool-health-wrap');
  wrap.innerHTML = '<p class="hint">Loading pool status…</p>';

  var results = {};
  var pending = poolNames.length;

  function done() {
    pending--;
    if (pending === 0) renderPoolHealth(poolNames, results);
  }

  poolNames.forEach(function(pool) {
    cockpit.spawn(['/usr/bin/zpool', 'status', '-v', pool], {superuser: 'try', err: 'message'})
      .then(function(out) { results[pool] = out; done(); })
      .catch(function()   { results[pool] = '';  done(); });
  });
}

function renderPoolHealth(poolNames, results) {
  document.getElementById('pool-health-wrap').innerHTML =
    poolNames.map(function(p) { return renderHealthCard(p, parseZpoolStatus(results[p] || '')); }).join('');
}

function parseZpoolStatus(output) {
  var res = {state: '', scan: '', errors: '', config: []};
  var lines = output.split('\n');
  var inConfig = false, inScan = false, scanBuf = [];

  lines.forEach(function(line) {
    var m;
    if ((m = line.match(/^\s*state:\s*(.+)/)))        { res.state = m[1].trim(); inConfig = inScan = false; }
    else if ((m = line.match(/^\s*scan:\s*(.*)/)))    { scanBuf = [m[1].trim()]; inScan = true; inConfig = false; }
    else if (inScan && /^\s{6}/.test(line) && line.trim()) { scanBuf.push(line.trim()); }
    else if (line.match(/^\s*config:/))               { inScan = false; inConfig = true; if (scanBuf.length) res.scan = scanBuf.join(' '); }
    else if (inConfig && line.trim() && !line.match(/^\s*NAME\s+STATE/)) { res.config.push(line); }
    else if ((m = line.match(/^\s*errors:\s*(.*)/)))  { res.errors = m[1].trim(); inConfig = inScan = false; }
    else if (inScan && line.trim())                   { inScan = false; if (scanBuf.length) res.scan = scanBuf.join(' '); }
  });
  if (inScan && scanBuf.length) res.scan = scanBuf.join(' ');
  return res;
}

function renderHealthCard(poolName, p) {
  var stBadge = p.state === 'ONLINE'
    ? '<span class="badge badge-ok">ONLINE</span>'
    : p.state
      ? '<span class="badge badge-warn">' + esc(p.state) + '</span>'
      : '<span class="badge badge-warn">Unknown</span>';

  // Scrub info
  var scanHtml;
  if (!p.scan || p.scan === 'none requested') {
    scanHtml = '<span style="color:#6a6e73">Never run</span>';
  } else if (p.scan.indexOf('in progress') !== -1 || p.scan.indexOf('resilver') !== -1) {
    scanHtml = '<span style="color:#795600">⟳ ' + esc(p.scan) + '</span>';
  } else {
    var errN = (p.scan.match(/with (\d+) error/) || [])[1];
    var hasErr = errN && parseInt(errN) > 0;
    scanHtml = '<span style="color:' + (hasErr ? '#c9190b' : '#3e8635') + '">' +
      (hasErr ? '⚠ ' : '✓ ') + esc(p.scan) + '</span>';
  }

  var scrubInProgress = p.scan.indexOf('in progress') !== -1;
  var hasDataErrors = p.errors && p.errors !== 'No known data errors';

  // Config block — trim trailing empty lines, preserve indentation
  var configTxt = p.config.map(function(l) { return l; }).join('\n').trimRight();

  return '<div class="enc-section">' +
    '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">' +
      '<strong>' + esc(poolName) + '</strong>' + stBadge +
    '</div>' +
    '<dl class="dl" style="grid-template-columns:120px 1fr;margin-bottom:12px">' +
      '<dt>Last scrub</dt><dd>' + scanHtml + '</dd>' +
      '<dt>Data errors</dt><dd>' + (hasDataErrors
        ? '<span style="color:#c9190b">⚠ ' + esc(p.errors) + '</span>'
        : '<span style="color:#3e8635">None</span>') + '</dd>' +
    '</dl>' +
    (configTxt ? '<pre class="output-pre" style="font-size:12px;margin-bottom:12px">' +
      'NAME                   STATE     READ WRITE CKSUM\n' + esc(configTxt) + '</pre>' : '') +
    '<div style="display:flex;gap:8px">' +
      '<button class="btn btn-secondary" style="font-size:12px" ' +
        'data-action="' + (scrubInProgress ? 'cancel-scrub' : 'run-scrub') + '" ' +
        'data-pool="' + esc(poolName) + '">' +
        (scrubInProgress ? 'Cancel scrub' : 'Run scrub now') +
      '</button>' +
      (scrubInProgress ? '<button class="btn btn-secondary" style="font-size:12px" ' +
        'data-action="refresh-health" data-pool="' + esc(poolName) + '">↻ Refresh progress</button>' : '') +
    '</div>' +
  '</div>';
}

document.getElementById('pool-health-wrap').addEventListener('click', function(e) {
  var btn = e.target.closest('[data-action]');
  if (!btn) return;
  var pool = btn.dataset.pool;
  if (btn.dataset.action === 'run-scrub') {
    btn.disabled = true;
    btn.textContent = 'Starting scrub…';
    cockpit.spawn(['/usr/bin/zpool', 'scrub', pool], {superuser: 'require', err: 'message'})
      .then(function() { loadPoolHealth([pool]); })
      .catch(function(err) {
        btn.disabled = false;
        btn.textContent = 'Run scrub now';
        alert('Scrub failed: ' + String(err.message || err));
      });
  } else if (btn.dataset.action === 'cancel-scrub') {
    btn.disabled = true;
    cockpit.spawn(['/usr/bin/zpool', 'scrub', '-s', pool], {superuser: 'require', err: 'message'})
      .then(function() { loadPoolHealth([pool]); })
      .catch(function(err) {
        btn.disabled = false;
        alert('Cancel failed: ' + String(err.message || err));
      });
  } else if (btn.dataset.action === 'refresh-health') {
    loadPoolHealth([pool]);
  }
});

// ── ZFS Encryption ────────────────────────────────────────────────────────────

function checkUnlockStatus() {
  cockpit.spawn(['/usr/bin/cat', '/run/pinneos/unlock-needed'], {err: 'message'})
    .then(function(content) {
      var poolName = (content || '').trim();
      if (poolName) renderUnlockBanner(poolName);
      else hideUnlockBanner();
    })
    .catch(function() { hideUnlockBanner(); });
}

function renderUnlockBanner(poolName) {
  var el = document.getElementById('unlock-banner');
  el.innerHTML =
    '<div class="alert alert-warning">' +
      '<p style="margin-bottom:10px"><strong>Pool "' + esc(poolName) + '" is encrypted and locked.</strong><br>' +
        'Enter the passphrase to unlock and start Docker containers.</p>' +
      '<div class="row" style="flex-wrap:wrap;gap:8px;margin-bottom:8px">' +
        '<input type="password" id="unlock-passphrase" placeholder="Passphrase">' +
        '<button class="btn btn-primary" id="btn-do-unlock">Unlock</button>' +
        '<button class="btn btn-secondary" style="font-size:12px" id="btn-show-recovery-unlock">Use recovery key</button>' +
      '</div>' +
      '<div id="unlock-alert"></div>' +
      '<div id="unlock-recovery-section" style="display:none;margin-top:10px">' +
        '<div class="form-group" style="margin-bottom:8px">' +
          '<label>Recovery key (64 lowercase hex characters)</label>' +
          '<input type="text" id="unlock-recovery-input" placeholder="a3f7c2…8b91d4" style="max-width:440px;font-family:monospace">' +
        '</div>' +
        '<button class="btn btn-primary" id="btn-do-unlock-recovery">Unlock with recovery key</button>' +
      '</div>' +
    '</div>';
  el.style.display = '';

  document.getElementById('btn-do-unlock').addEventListener('click', function() { unlockPool(poolName); });
  document.getElementById('btn-show-recovery-unlock').addEventListener('click', function() {
    document.getElementById('unlock-recovery-section').style.display = '';
  });
  document.getElementById('btn-do-unlock-recovery').addEventListener('click', function() {
    unlockPoolRecovery(poolName);
  });
}

function hideUnlockBanner() {
  var el = document.getElementById('unlock-banner');
  el.style.display = 'none';
  el.innerHTML = '';
}

function unlockPool(poolName) {
  var pass = document.getElementById('unlock-passphrase').value;
  if (!pass) return;
  var alertEl = document.getElementById('unlock-alert');
  alertEl.innerHTML = '<span class="hint">Unlocking…</span>';
  document.getElementById('btn-do-unlock').disabled = true;

  cockpit.spawn(['/usr/lib/homelab/zfs-encrypt.sh', 'unlock', poolName],
      {superuser: 'require', err: 'message'})
    .input(pass + '\n')
    .then(function() {
      alertEl.innerHTML = '<span style="color:#1e4f18">Unlocked — restarting Docker…</span>';
      document.getElementById('unlock-passphrase').value = '';
      return cockpit.spawn(['/usr/bin/systemctl', 'restart', 'docker'],
          {superuser: 'require', err: 'message'});
    })
    .then(function() { hideUnlockBanner(); loadPools(); })
    .catch(function(err) {
      alertEl.innerHTML = '<span style="color:#c9190b">✗ ' + esc(String(err.message || err)) + '</span>';
      document.getElementById('btn-do-unlock').disabled = false;
    });
}

function unlockPoolRecovery(poolName) {
  var hex = (document.getElementById('unlock-recovery-input').value || '').trim().toLowerCase();
  var alertEl = document.getElementById('unlock-alert');
  if (!/^[0-9a-f]{64}$/.test(hex)) {
    alertEl.innerHTML = '<span style="color:#c9190b">Invalid recovery key — must be 64 lowercase hex characters.</span>';
    return;
  }
  alertEl.innerHTML = '<span class="hint">Unlocking…</span>';
  document.getElementById('btn-do-unlock-recovery').disabled = true;

  cockpit.spawn(['/usr/lib/homelab/zfs-encrypt.sh', 'unlock-recovery', poolName],
      {superuser: 'require', err: 'message'})
    .input(hex + '\n')
    .then(function() {
      alertEl.innerHTML = '<span style="color:#1e4f18">Unlocked — restarting Docker…</span>';
      return cockpit.spawn(['/usr/bin/systemctl', 'restart', 'docker'],
          {superuser: 'require', err: 'message'});
    })
    .then(function() { hideUnlockBanner(); loadPools(); })
    .catch(function(err) {
      alertEl.innerHTML = '<span style="color:#c9190b">✗ ' + esc(String(err.message || err)) + '</span>';
      document.getElementById('btn-do-unlock-recovery').disabled = false;
    });
}

function renderEncryptionCard(encryptedPools) {
  var card = document.getElementById('card-encryption');
  if (!encryptedPools.length) { card.style.display = 'none'; return; }
  card.style.display = '';
  var wrap = document.getElementById('encryption-manage-wrap');
  wrap.innerHTML = '';

  encryptedPools.forEach(function(p) {
    var isUnlocked = p.keystatus === 'available';
    var badge = isUnlocked
      ? '<span class="badge badge-ok">Unlocked</span>'
      : '<span class="badge badge-lock">Locked</span>';
    var eid = 'enc-' + p.name.replace(/[^a-zA-Z0-9]/g, '_');

    var html = '<div class="enc-section">' +
      '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:' +
        (isUnlocked ? '12' : '0') + 'px">' +
        '<strong>' + esc(p.name) + '</strong>' + badge +
      '</div>';

    if (isUnlocked) {
      html +=
        '<p style="font-size:12px;font-weight:600;margin:0 0 8px;color:#6a6e73;text-transform:uppercase;letter-spacing:.04em">Change passphrase</p>' +
        '<div class="form-group" style="margin-bottom:8px">' +
          '<label>Current passphrase</label>' +
          '<input type="password" id="' + eid + '-old">' +
        '</div>' +
        '<div class="form-group" style="margin-bottom:8px">' +
          '<label>New passphrase (min 12 chars)</label>' +
          '<input type="password" id="' + eid + '-new1">' +
        '</div>' +
        '<div class="form-group" style="margin-bottom:8px">' +
          '<label>Confirm new passphrase</label>' +
          '<input type="password" id="' + eid + '-new2">' +
        '</div>' +
        '<button class="btn btn-primary" id="' + eid + '-btn-chpass">Save new passphrase</button>' +
        '<div id="' + eid + '-chpass-alert" style="margin-top:8px"></div>' +
        '<hr style="margin:16px 0;border:none;border-top:1px solid #d2d2d2">' +
        '<p style="font-size:12px;font-weight:600;margin:0 0 8px;color:#6a6e73;text-transform:uppercase;letter-spacing:.04em">Auto-unlock on boot</p>' +
        '<div id="' + eid + '-kf-info"><span class="hint">Checking…</span></div>';
    }

    html += '</div>';
    wrap.insertAdjacentHTML('beforeend', html);

    if (isUnlocked) {
      var pn = p.name;
      document.getElementById(eid + '-btn-chpass').addEventListener('click', function() {
        changePassphrase(pn, eid);
      });
      checkKeyfileStatus(pn, eid);
    }
  });
}

function changePassphrase(poolName, eid) {
  var old1 = document.getElementById(eid + '-old').value;
  var new1 = document.getElementById(eid + '-new1').value;
  var new2 = document.getElementById(eid + '-new2').value;
  var alertEl = document.getElementById(eid + '-chpass-alert');

  if (!old1) { showAlert(eid + '-chpass-alert', 'warning', 'Enter current passphrase.'); return; }
  if (new1.length < 12) { showAlert(eid + '-chpass-alert', 'warning', 'New passphrase must be at least 12 characters.'); return; }
  if (new1 !== new2) { showAlert(eid + '-chpass-alert', 'warning', 'Passphrases do not match.'); return; }

  showAlert(eid + '-chpass-alert', 'warning', 'Changing passphrase…');
  document.getElementById(eid + '-btn-chpass').disabled = true;

  cockpit.spawn(['/usr/lib/homelab/zfs-encrypt.sh', 'change-passphrase', poolName],
      {superuser: 'require', err: 'message'})
    .input(old1 + '\n' + new1 + '\n')
    .then(function() {
      showAlert(eid + '-chpass-alert', 'success', 'Passphrase changed.');
      [eid + '-old', eid + '-new1', eid + '-new2'].forEach(function(id) {
        document.getElementById(id).value = '';
      });
      document.getElementById(eid + '-btn-chpass').disabled = false;
    })
    .catch(function(err) {
      showAlert(eid + '-chpass-alert', 'danger', String(err.message || err));
      document.getElementById(eid + '-btn-chpass').disabled = false;
    });
}

function checkKeyfileStatus(poolName, eid) {
  var infoEl = document.getElementById(eid + '-kf-info');
  infoEl.innerHTML = '<span class="hint">Checking…</span>';

  var rawKey = '/run/pinneos/persist/encryption/' + poolName + '.key';
  var encKey = '/run/pinneos/persist/encryption/' + poolName + '.key.enc';

  // Sequential cockpit spawn checks — cockpit chains don't unwrap native Promise.all
  cockpit.spawn(['/usr/bin/test', '-f', rawKey], {superuser: 'try', err: 'message'})
    .then(function() {
      // State 1: Raw key present — auto-unlock enabled
      infoEl.innerHTML =
        '<div class="alert alert-success" style="display:flex;justify-content:space-between;align-items:center">' +
          '<span>Auto-unlock at boot: <strong>Enabled</strong> — pool unlocks automatically without any login.</span>' +
          '<button class="btn btn-danger-sm" id="' + eid + '-btn-rmkf">Disable</button>' +
        '</div>';
      document.getElementById(eid + '-btn-rmkf').addEventListener('click', function() {
        removeKeyfile(poolName, eid);
      });
    })
    .catch(function() {
      // No raw key — check for encrypted keyfile
      cockpit.spawn(['/usr/bin/test', '-f', encKey], {superuser: 'try', err: 'message'})
        .then(function() {
          // State 2: Only .key.enc — can re-enable with just passphrase
          infoEl.innerHTML =
            '<div class="alert alert-warning" style="margin-bottom:8px">' +
              'Auto-unlock at boot: <strong>Disabled</strong> — passphrase required at each boot.' +
            '</div>' +
            '<div class="form-group" style="margin-bottom:8px">' +
              '<label>Passphrase</label>' +
              '<input type="password" id="' + eid + '-kf-pass" autocomplete="current-password">' +
            '</div>' +
            '<button class="btn btn-primary" id="' + eid + '-btn-savekf">Enable auto-unlock</button>' +
            '<div id="' + eid + '-kf-alert" style="margin-top:8px"></div>' +
            '<p style="margin:8px 0 0;font-size:12px">' +
              '<a href="#" id="' + eid + '-lnk-rmall" style="color:#c9190b">Remove all keyfiles from USB</a>' +
              ' (requires recovery key to re-enable)' +
            '</p>';
          document.getElementById(eid + '-btn-savekf').addEventListener('click', function() {
            extractKeyfile(poolName, eid);
          });
          document.getElementById(eid + '-lnk-rmall').addEventListener('click', function(e) {
            e.preventDefault();
            removeKeyfileAll(poolName, eid);
          });
        })
        .catch(function() {
          // State 3: No keyfile at all — needs passphrase + recovery key
          infoEl.innerHTML =
            '<div class="alert alert-warning" style="margin-bottom:8px">' +
              'No keyfile on USB — passphrase <em>and</em> recovery key needed to set up auto-unlock.' +
            '</div>' +
            '<div class="form-group" style="margin-bottom:8px">' +
              '<label>Passphrase (min 12 chars)</label>' +
              '<input type="password" id="' + eid + '-kf-pass" autocomplete="new-password">' +
            '</div>' +
            '<div class="form-group" style="margin-bottom:8px">' +
              '<label>Recovery key (64 hex chars)</label>' +
              '<input type="text" id="' + eid + '-kf-rec" placeholder="a3f7c2…8b91d4" style="font-family:monospace">' +
            '</div>' +
            '<button class="btn btn-primary" id="' + eid + '-btn-savekf">Save keyfile to USB</button>' +
            '<div id="' + eid + '-kf-alert" style="margin-top:8px"></div>';
          document.getElementById(eid + '-btn-savekf').addEventListener('click', function() {
            saveKeyfile(poolName, eid);
          });
        });
    });
}

function removeKeyfile(poolName, eid) {
  if (!window.confirm('Disable auto-unlock for pool "' + poolName + '"?\n\nThe encrypted keyfile is kept on USB — you can re-enable auto-unlock with just your passphrase.')) return;
  cockpit.spawn(['/usr/lib/homelab/zfs-encrypt.sh', 'remove-keyfile', poolName],
      {superuser: 'require', err: 'message'})
    .then(function() { checkKeyfileStatus(poolName, eid); })
    .catch(function(err) {
      document.getElementById(eid + '-kf-info').innerHTML =
        '<div class="alert alert-danger">' + esc(String(err.message || err)) + '</div>';
    });
}

function removeKeyfileAll(poolName, eid) {
  if (!window.confirm('Remove ALL keyfiles for pool "' + poolName + '" from USB?\n\nYou will need your passphrase AND recovery key to set up auto-unlock again.')) return;
  cockpit.spawn(['/usr/lib/homelab/zfs-encrypt.sh', 'remove-keyfile-all', poolName],
      {superuser: 'require', err: 'message'})
    .then(function() { checkKeyfileStatus(poolName, eid); })
    .catch(function(err) {
      document.getElementById(eid + '-kf-info').innerHTML =
        '<div class="alert alert-danger">' + esc(String(err.message || err)) + '</div>';
    });
}

function extractKeyfile(poolName, eid) {
  var pass = (document.getElementById(eid + '-kf-pass') || {}).value || '';
  var alertId = eid + '-kf-alert';
  if (pass.length < 12) { showAlert(alertId, 'warning', 'Passphrase must be at least 12 characters.'); return; }
  showAlert(alertId, 'warning', 'Enabling auto-unlock…');
  cockpit.spawn(['/usr/lib/homelab/zfs-encrypt.sh', 'extract-keyfile', poolName],
      {superuser: 'require', err: 'message'})
    .input(pass + '\n')
    .then(function() { checkKeyfileStatus(poolName, eid); })
    .catch(function(err) { showAlert(alertId, 'danger', String(err.message || err)); });
}

function saveKeyfile(poolName, eid) {
  var pass = (document.getElementById(eid + '-kf-pass') || {}).value || '';
  var rec  = ((document.getElementById(eid + '-kf-rec') || {}).value || '').trim().toLowerCase();
  var alertId = eid + '-kf-alert';
  if (pass.length < 12) { showAlert(alertId, 'warning', 'Passphrase must be at least 12 characters.'); return; }
  if (!/^[0-9a-f]{64}$/.test(rec)) { showAlert(alertId, 'warning', 'Invalid recovery key format.'); return; }
  showAlert(alertId, 'warning', 'Saving keyfile…');
  cockpit.spawn(['/usr/lib/homelab/zfs-encrypt.sh', 'save-keyfile', poolName],
      {superuser: 'require', err: 'message'})
    .input(pass + '\n' + rec + '\n')
    .then(function() { checkKeyfileStatus(poolName, eid); })
    .catch(function(err) { showAlert(alertId, 'danger', String(err.message || err)); });
}

// ── Recovery key modal ────────────────────────────────────────────────────────

var _recoveryPoolName = '';
var _recoveryHex = '';

function showRecoveryKeyModal(poolName, hex) {
  if (!hex || !/^[0-9a-f]{64}$/.test(hex)) return;
  _recoveryPoolName = poolName;
  _recoveryHex = hex;
  document.getElementById('recovery-key-hex').value = hex;
  document.getElementById('recovery-key-copy-alert').textContent = '';
  document.getElementById('modal-overlay').style.display = 'flex';
}

function copyRecoveryKey() {
  var ta = document.getElementById('recovery-key-hex');
  ta.select();
  ta.setSelectionRange(0, 99999);
  var ok = false;
  try { ok = document.execCommand('copy'); } catch(e) {}
  var alertEl = document.getElementById('recovery-key-copy-alert');
  if (ok) {
    alertEl.className = 'alert alert-success';
    alertEl.textContent = 'Copied to clipboard.';
  } else {
    alertEl.className = 'alert alert-warning';
    alertEl.textContent = 'Auto-copy failed — select the key above and press Ctrl+C.';
  }
}

function downloadRecoveryKey() {
  // data: URI works without HTTPS and in Cockpit iframes
  var uri = 'data:text/plain;charset=utf-8,' + encodeURIComponent(_recoveryHex + '\n');
  var a = document.createElement('a');
  a.href = uri;
  a.download = 'recovery-key-' + _recoveryPoolName + '.txt';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
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

// ── USB Mirror (Setup tab) ────────────────────────────────────────────────────
//
// Both USB sticks are equal mirrors — no "primary vs backup" distinction.
// usb-mirror-sync.sh syncs Slot A, Slot B and grubenv from the boot USB to
// any other connected PinneOS USB. No registration required.

function loadUsbMirror() {
  var wrap = document.getElementById('usb-mirror-status');
  wrap.innerHTML = '<p class="empty-text">Scanning for mirror USB…</p>';
  findBootDisk()
    .then(function(bootDisk) { return findMirrorDisks(bootDisk); })
    .then(function(mirrors)  { renderUsbMirrorStatus(mirrors); })
    .catch(function()        { renderUsbMirrorStatus([]); });
}

// Identify the boot disk by tracing the persist mount back to its parent.
// Avoids findfs LABEL=PINNEOS_A ambiguity when two PinneOS USBs are connected.
function findBootDisk() {
  return cockpit.spawn(
    ['/usr/bin/findmnt', '-n', '-o', 'SOURCE', '/run/pinneos/persist'],
    {err: 'message'}
  ).then(function(part) {
    return cockpit.spawn(['/usr/bin/lsblk', '-no', 'PKNAME', part.trim()], {err: 'message'});
  }).then(function(out) { return '/dev/' + out.trim(); })
  .catch(function() { return ''; });
}

// Return all non-boot disks that have a PINNEOS_A partition (i.e. PinneOS USBs).
function findMirrorDisks(bootDisk) {
  return cockpit.spawn(
    ['/usr/bin/lsblk', '-J', '-b', '-o', 'NAME,SIZE,MODEL,TYPE,LABEL'],
    {err: 'message'}
  ).then(function(output) {
    var data = JSON.parse(output);
    var mirrors = [];
    (data.blockdevices || []).forEach(function(dev) {
      if (dev.type !== 'disk') return;
      var disk = '/dev/' + dev.name;
      if (disk === bootDisk) return;
      var hasPinneosA = (dev.children || []).some(function(c) { return c.label === 'PINNEOS_A'; });
      if (!hasPinneosA) return;
      mirrors.push({ disk: disk, model: (dev.model || 'Unknown').trim(), size: dev.size });
    });
    return mirrors;
  });
}

function renderUsbMirrorStatus(mirrors) {
  var wrap = document.getElementById('usb-mirror-status');
  if (!mirrors.length) {
    wrap.innerHTML =
      '<div class="alert alert-warning" style="margin-bottom:0">' +
        'No mirror USB detected. ' +
        'Write the .img.gz to a second USB with Etcher, plug it in, then click ↻ Refresh.' +
      '</div>';
    return;
  }
  var html = '';
  mirrors.forEach(function(m) {
    html +=
      '<div class="alert alert-success" style="display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:8px">' +
        '<div>' +
          '<strong>Mirror connected</strong> — ' +
          '<span class="disk-name">' + esc(m.disk) + '</span> ' +
          '<span class="disk-meta">' + esc(m.model) + ' ' + fmtBytes(m.size) + '</span>' +
        '</div>' +
        '<button class="btn btn-primary" data-action="sync-mirror" data-disk="' + esc(m.disk) + '">Sync now</button>' +
      '</div>';
  });
  wrap.innerHTML = html;
}

function syncMirrorNow(disk) {
  var logEl = document.getElementById('usb-mirror-log');
  logEl.style.display = '';
  logEl.textContent = 'Syncing ' + disk + '…\n';
  clearAlert('usb-mirror-alert');

  var proc = cockpit.spawn(
    ['/usr/lib/homelab/usb-mirror-sync.sh', disk],
    {superuser: 'try', err: 'message'}
  );
  proc.stream(function(data) { logEl.textContent += data; logEl.scrollTop = logEl.scrollHeight; });
  proc.then(function() {
    logEl.textContent += '\n✓ Mirror sync complete.';
    showAlert('usb-mirror-alert', 'success', 'Mirror sync complete.');
  });
  proc.catch(function(err) {
    logEl.textContent += '\n✗ Error: ' + String(err.message || err);
    showAlert('usb-mirror-alert', 'danger', String(err.message || err));
  });
}

// ── Update tab ────────────────────────────────────────────────────────────────

var _updateLocalFile = null;

function loadUpdateTab() {
  clearAlert('update-alert');
  clearLog('update-log');
  document.getElementById('update-reboot-wrap').style.display = 'none';

  cockpit.spawn(['cat', '/etc/homelab/version'], {err: 'ignore'})
    .then(function(v) {
      document.getElementById('update-current-version').textContent = v.trim() || 'unknown';
    })
    .catch(function() {
      document.getElementById('update-current-version').textContent = 'unknown';
    });

  checkUpdateState();
}

function checkUpdateState() {
  var availEl    = document.getElementById('update-available-version');
  var linkEl     = document.getElementById('update-release-link');
  var installBtn = document.getElementById('btn-install-github');

  availEl.textContent = 'checking…';
  availEl.style.color = '';

  cockpit.spawn(['cat', '/run/pinneos/update-available'], {err: 'ignore'})
    .then(function(v) {
      v = v.trim();
      if (v === 'up-to-date') {
        availEl.textContent = 'up to date';
        availEl.style.color = '#3e8635';
        linkEl.style.display = 'none';
        installBtn.disabled = true;
      } else if (v) {
        availEl.textContent = v;
        availEl.style.color = '#c9190b';
        cockpit.spawn(['sh', '-c', '. /etc/homelab/config; echo "$UPDATE_CHECK_URL"'], {err: 'ignore'})
          .then(function(url) {
            url = url.trim();
            var webUrl = url
              .replace('api.github.com/repos', 'github.com')
              .replace('/releases/latest', '/releases/tag/v' + v);
            linkEl.href = webUrl;
            linkEl.style.display = '';
          })
          .catch(function() { linkEl.style.display = 'none'; });
        installBtn.disabled = false;
      } else {
        availEl.textContent = 'not checked yet';
        availEl.style.color = '#6a6e73';
        linkEl.style.display = 'none';
        installBtn.disabled = true;
      }
    })
    .catch(function() {
      availEl.textContent = 'not checked yet';
      availEl.style.color = '#6a6e73';
      linkEl.style.display = 'none';
      installBtn.disabled = true;
    });
}

function runUpdateCheck() {
  var btn = document.getElementById('btn-check-update');
  btn.disabled = true;
  clearAlert('update-alert');
  document.getElementById('update-available-version').textContent = 'checking…';
  document.getElementById('update-available-version').style.color = '';
  document.getElementById('update-release-link').style.display = 'none';
  document.getElementById('btn-install-github').disabled = true;

  cockpit.spawn(['/usr/lib/homelab/update-check.sh'], {superuser: 'try', err: 'message'})
    .then(function() { checkUpdateState(); })
    .catch(function(err) {
      document.getElementById('update-available-version').textContent = 'check failed';
      showAlert('update-alert', 'danger', 'Update check failed: ' + (err.message || String(err)));
    })
    .finally(function() { btn.disabled = false; });
}

function handleUpdateFileSelect(e) {
  var file = e.target.files[0];
  if (!file) {
    _updateLocalFile = null;
    document.getElementById('update-file-status').textContent = '';
    document.getElementById('btn-install-file').disabled = true;
    return;
  }
  _updateLocalFile = file;
  document.getElementById('update-file-status').textContent =
    file.name + ' (' + fmtBytes(file.size) + ')';
  document.getElementById('btn-install-file').disabled = false;
}

function runUpdateFromFile() {
  if (!_updateLocalFile) return;
  var btn = document.getElementById('btn-install-file');
  btn.disabled = true;
  document.getElementById('btn-install-github').disabled = true;
  clearAlert('update-alert');
  clearLog('update-log');
  document.getElementById('update-reboot-wrap').style.display = 'none';
  appendLog('update-log', 'Reading file…\n');

  var ext = _updateLocalFile.name.endsWith('.iso') ? '.iso' : '.img.gz';
  var tmpPath = '/tmp/pinneos-update-upload' + ext;

  var reader = new FileReader();
  reader.onprogress = function(ev) {
    if (ev.lengthComputable) {
      var pct = Math.round(ev.loaded / ev.total * 100);
      var el = document.getElementById('update-log');
      if (el) { el.textContent = 'Reading file… ' + pct + '%\n'; }
    }
  };
  reader.onload = function(ev) {
    appendLog('update-log', 'Uploading to server…\n');
    var data = new Uint8Array(ev.target.result);
    cockpit.file(tmpPath, {binary: true}).replace(data)
      .then(function() {
        appendLog('update-log', 'Upload complete. Starting update…\n');
        var proc = cockpit.spawn(
          ['/usr/lib/homelab/update.sh', '--file', tmpPath],
          {superuser: 'try', err: 'message'}
        );
        proc.stream(function(chunk) { appendLog('update-log', chunk); });
        proc.then(function() {
          appendLog('update-log', '\n✓ Update written to standby slot.\n');
          showAlert('update-alert', 'success', 'Update installed. Click "Reboot now" to boot into the new slot.');
          document.getElementById('update-reboot-wrap').style.display = '';
          btn.disabled = false;
          cockpit.spawn(['rm', '-f', tmpPath], {superuser: 'try'}).catch(function(){});
        });
        proc.catch(function(err) {
          appendLog('update-log', '\n✗ Error: ' + String(err.message || err));
          showAlert('update-alert', 'danger', 'Update failed: ' + (err.message || String(err)));
          btn.disabled = false;
          document.getElementById('btn-install-github').disabled = false;
          cockpit.spawn(['rm', '-f', tmpPath], {superuser: 'try'}).catch(function(){});
        });
      })
      .catch(function(err) {
        appendLog('update-log', '\n✗ Upload failed: ' + String(err.message || err));
        showAlert('update-alert', 'danger', 'Upload failed: ' + (err.message || String(err)));
        btn.disabled = false;
        document.getElementById('btn-install-github').disabled = false;
      });
  };
  reader.onerror = function() {
    appendLog('update-log', '\n✗ Error reading file.\n');
    btn.disabled = false;
    document.getElementById('btn-install-github').disabled = false;
  };
  reader.readAsArrayBuffer(_updateLocalFile);
}

function runUpdateFromGithub() {
  var btn = document.getElementById('btn-install-github');
  btn.disabled = true;
  document.getElementById('btn-install-file').disabled = true;
  clearAlert('update-alert');
  clearLog('update-log');
  document.getElementById('update-reboot-wrap').style.display = 'none';

  var proc = cockpit.spawn(
    ['/usr/lib/homelab/update.sh'],
    {superuser: 'try', err: 'message'}
  );
  proc.stream(function(chunk) { appendLog('update-log', chunk); });
  proc.then(function() {
    appendLog('update-log', '\n✓ Update written to standby slot.\n');
    showAlert('update-alert', 'success', 'Update installed. Click "Reboot now" to boot into the new slot.');
    document.getElementById('update-reboot-wrap').style.display = '';
    btn.disabled = false;
  });
  proc.catch(function(err) {
    appendLog('update-log', '\n✗ Error: ' + String(err.message || err));
    showAlert('update-alert', 'danger', 'Update failed: ' + (err.message || String(err)));
    btn.disabled = false;
    if (_updateLocalFile) document.getElementById('btn-install-file').disabled = false;
  });
}

// ── Wire up static controls ───────────────────────────────────────────────────

document.getElementById('tab-btn-setup').addEventListener('click',   function() { switchTab('setup');  });
document.getElementById('tab-btn-zfs').addEventListener('click',     function() { switchTab('zfs');    });
document.getElementById('tab-btn-backup').addEventListener('click',  function() { switchTab('backup'); });
document.getElementById('tab-btn-access').addEventListener('click',  function() { switchTab('access'); });
document.getElementById('tab-btn-update').addEventListener('click',  function() { switchTab('update'); });

document.getElementById('btn-check-update').addEventListener('click', runUpdateCheck);
document.getElementById('btn-install-github').addEventListener('click', runUpdateFromGithub);
document.getElementById('btn-install-file').addEventListener('click', runUpdateFromFile);
document.getElementById('update-file-input').addEventListener('change', handleUpdateFileSelect);
document.getElementById('btn-reboot-now').addEventListener('click', function() {
  if (confirm('Reboot now?')) {
    cockpit.spawn(['reboot'], {superuser: 'require'}).catch(function(){});
  }
});

document.getElementById('btn-run-backup').addEventListener('click', runBackup);
document.getElementById('btn-list-backups').addEventListener('click', listBackups);
document.getElementById('btn-run-restore').addEventListener('click', runRestore);

document.getElementById('hostname-input').addEventListener('input', updateHostnamePreview);
document.getElementById('btn-save-hostname').addEventListener('click', saveHostname);
document.getElementById('btn-save-password').addEventListener('click', savePassword);

document.getElementById('btn-refresh-pool-health').addEventListener('click', function() {
  cockpit.spawn(['/usr/bin/zpool', 'list', '-H', '-o', 'name'], {err: 'message'})
    .then(function(out) {
      loadPoolHealth(out.trim().split('\n').filter(Boolean));
    })
    .catch(function() { loadPoolHealth([]); });
});
document.getElementById('btn-release-mounts').addEventListener('click', releaseDockerMounts);
document.getElementById('btn-show-create-pool').addEventListener('click', function() {
  document.getElementById('create-pool-form').style.display = '';
  clearAlert('create-pool-alert');
});
document.getElementById('btn-cancel-create-pool').addEventListener('click', function() {
  document.getElementById('create-pool-form').style.display = 'none';
  document.getElementById('encrypt-pool').checked = false;
  document.getElementById('encrypt-fields').style.display = 'none';
});

document.getElementById('encrypt-pool').addEventListener('change', function() {
  document.getElementById('encrypt-fields').style.display = this.checked ? '' : 'none';
});

document.getElementById('btn-copy-recovery-key').addEventListener('click', copyRecoveryKey);
document.getElementById('btn-download-recovery-key').addEventListener('click', downloadRecoveryKey);
document.getElementById('btn-close-recovery-modal').addEventListener('click', function() {
  document.getElementById('modal-overlay').style.display = 'none';
  _recoveryHex = '';
  _recoveryPoolName = '';
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

document.getElementById('usb-mirror-status').addEventListener('click', function(e) {
  var btn = e.target.closest('[data-action]');
  if (!btn) return;
  if (btn.dataset.action === 'sync-mirror') syncMirrorNow(btn.dataset.disk);
});

document.getElementById('btn-refresh-usb-mirror').addEventListener('click', function() {
  clearAlert('usb-mirror-alert');
  loadUsbMirror();
});

// ── Init ──────────────────────────────────────────────────────────────────────

switchTab('setup');
loadHostname();
loadUsbMirror();
