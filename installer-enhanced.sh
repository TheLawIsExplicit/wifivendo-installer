#!/data/data/com.termux/files/usr/bin/bash

# 1. Update & Install Essentials
pkg update && pkg upgrade -y
pkg install -y git php php-fpm nginx sqlite python wget nano

# 2. Create Main Folder
mkdir -p ~/vendo/{www,qrcodes}
cd ~/vendo

# 3. Create Config File (time/data rates)
cat > www/config.json <<EOF
{
  "access_mode": "time",
  "rates": {
    "1": {"time": 1200, "data": 24},
    "5": {"time": 3600, "data": 128},
    "10": {"time": 7200, "data": 1024},
    "20": {"time": 7200, "data": 2048}
  }
}
EOF

# 4. Create voucher DB
sqlite3 www/vouchers.db <<EOF
CREATE TABLE IF NOT EXISTS vouchers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT UNIQUE,
  duration INTEGER,
  created_at DATETIME,
  used_at DATETIME,
  mac TEXT
);
EOF

# 5. Create data voucher DB
sqlite3 www/data_vouchers.db <<EOF
CREATE TABLE IF NOT EXISTS data_vouchers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT UNIQUE,
  data_limit INTEGER,
  used INTEGER DEFAULT 0,
  created_at DATETIME,
  mac TEXT,
  used_at DATETIME
);
EOF

# 6. Create basic login script
cat > www/login.php <<'EOF'
<?php
$config = json_decode(file_get_contents("config.json"), true);
$mode = $config["access_mode"];
$db = new SQLite3('vouchers.db');
$mac = $_POST['mac'];
$code = $_POST['voucher'];

$res = $db->query("SELECT * FROM vouchers WHERE code = '$code' AND used_at IS NULL")->fetchArray();
if ($res) {
  $db->exec("UPDATE vouchers SET used_at = datetime('now'), mac = '$mac' WHERE code = '$code'");
  shell_exec("iptables -t nat -I PREROUTING -m mac --mac-source $mac -j ACCEPT");
  echo "Access granted!";
} else {
  echo "Invalid or expired code.";
}
?>
EOF

# 7. Create status panel
cat > www/status.php <<'EOF'
<?php
$mac = exec("ip neigh | grep 'REACHABLE' | awk '{print $5}'");
$ip = $_SERVER['REMOTE_ADDR'];
echo "MAC Address: $mac<br>IP Address: $ip";
?>
EOF

# 8. Dashboard
cat > www/admin.php <<'EOF'
<?php
$db = new SQLite3('vouchers.db');
$res = $db->query("SELECT * FROM vouchers ORDER BY created_at DESC");

echo "<h2>Admin Dashboard</h2>";
echo "<table border='1'><tr><th>Code</th><th>Used</th><th>MAC</th><th>Time</th></tr>";
while ($row = $res->fetchArray()) {
  echo "<tr><td>{$row['code']}</td><td>" . ($row['used_at'] ? "Yes" : "No") . "</td><td>{$row['mac']}</td><td>{$row['duration']}</td></tr>";
}
echo "</table>";
?>
EOF

# 9. Transactions Log
cat > www/transactions.php <<'EOF'
<?php
$db = new SQLite3('vouchers.db');
$res = $db->query("SELECT * FROM vouchers WHERE used_at IS NOT NULL ORDER BY used_at DESC");
echo "<h2>Transaction History</h2><table border='1'><tr><th>Amount</th><th>Date</th><th>MAC</th><th>Code</th></tr>";
while ($row = $res->fetchArray()) {
  $amt = ($row['duration'] == 1200 ? "₱1.00" : ($row['duration'] == 3600 ? "₱5.00" : ($row['duration'] == 7200 ? "₱10.00" : "₱20.00")));
  echo "<tr><td>$amt</td><td>{$row['used_at']}</td><td>{$row['mac']}</td><td>{$row['code']}</td></tr>";
}
echo "</table>";
?>
EOF

# 10. Data Sharing Form
cat > www/data_sharing.php <<'EOF'
<form method="POST" action="share.php">
Code: <input type="text" name="code"><br>
MB Size: <input type="text" name="mb"><br>
<input type="submit" value="Share Data">
</form>
EOF

# 11. Data Sharing Handler
cat > www/share.php <<'EOF'
<?php
$db = new SQLite3('data_vouchers.db');
$code = $_POST['code'];
$mb = intval($_POST['mb']);
$db->exec("INSERT INTO data_vouchers (code, data_limit, created_at) VALUES ('$code', $mb, datetime('now'))");
echo "Shared $mb MB via code $code";
?>
EOF

# 12. Create settings panel
cat > www/settings.php <<'EOF'
<?php
$configFile = 'config.json';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $newConfig = [
        "access_mode" => $_POST['mode'],
        "rates" => [
            "1" => ["time" => intval($_POST['time1']), "data" => intval($_POST['data1'])],
            "5" => ["time" => intval($_POST['time5']), "data" => intval($_POST['data5'])],
            "10" => ["time" => intval($_POST['time10']), "data" => intval($_POST['data10'])],
            "20" => ["time" => intval($_POST['time20']), "data" => intval($_POST['data20'])]
        ]
    ];
    file_put_contents($configFile, json_encode($newConfig, JSON_PRETTY_PRINT));
    echo "<div>Settings saved!</div>";
}
$config = json_decode(file_get_contents($configFile), true);
?>
<form method="POST">
Mode: 
<select name="mode">
<option value="time" <?= $config['access_mode'] == 'time' ? 'selected' : '' ?>>Time</option>
<option value="data" <?= $config['access_mode'] == 'data' ? 'selected' : '' ?>>Data</option>
</select><br>
<?php foreach ($config['rates'] as $coin => $values): ?>
₱<?= $coin ?> Time: <input name="time<?= $coin ?>" value="<?= $values['time'] ?>"> MB: <input name="data<?= $coin ?>" value="<?= $values['data'] ?>"><br>
<?php endforeach; ?>
<input type="submit" value="Save">
</form>
EOF

# 13. Install nginx config
mkdir -p ~/nginx/conf/conf.d
wget -O ~/nginx/conf/mime.types https://raw.githubusercontent.com/nginx/nginx/master/conf/mime.types
wget -O ~/nginx/conf/fastcgi_params https://raw.githubusercontent.com/nginx/nginx/master/conf/fastcgi_params

cat > ~/nginx/conf/conf.d/default.conf <<EOF
server {
  listen 8080;
  root /data/data/com.termux/files/home/vendo/www;
  index index.html index.php;
  location ~ \\.php$ {
    fastcgi_pass 127.0.0.1:9000;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    include fastcgi_params;
  }
}
EOF

cat > ~/nginx/conf/nginx.conf <<EOF
worker_processes 1;
events { worker_connections 1024; }
http {
  include mime.types;
  default_type application/octet-stream;
  sendfile on;
  keepalive_timeout 65;
  include /data/data/com.termux/files/home/nginx/conf/conf.d/*.conf;
}
EOF

# 14. Launch servers
pkill php-fpm
php-fpm &
nginx -p ~/nginx -c ~/nginx/conf/nginx.conf

echo "✅ Enhanced WiFi Vendo System Installed!"
echo "🌐 Visit your TX6 IP at :8080 to test."
echo "🛜 Time and Data Vouchers ready with full control."
