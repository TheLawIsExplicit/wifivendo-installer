#!/data/data/com.termux/files/usr/bin/bash

# Step 1: Update Termux
pkg update && pkg upgrade -y

# Step 2: Install packages
pkg install -y git php php-fpm nginx sqlite python

# Step 3: Setup project folder
mkdir -p ~/vendo/{www,qrcodes}
cd ~/vendo

if [ ! -d www ]; then
  git clone https://github.com/foswvs/foswvs www
fi

# Step 4: Setup PHP DB (only if not exists)
if [ ! -f www/vouchers.db ]; then
sqlite3 www/vouchers.db <<EOF
CREATE TABLE vouchers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT UNIQUE,
  duration INTEGER,
  created_at DATETIME,
  used_at DATETIME,
  mac TEXT
);
EOF
fi

# Step 5: Write PHP login file
cat > www/login.php <<'EOF'
<?php
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

# Step 6: nginx config with proper structure
mkdir -p ~/nginx/conf/conf.d
cat > ~/nginx/conf/conf.d/default.conf <<EOF
server {
  listen 8080;
  root /data/data/com.termux/files/home/vendo/www;

  index index.html index.php;

  location ~ \.php$ {
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

# Step 7: Start servers
php-fpm &
nginx -p ~/nginx -c ~/nginx/conf/nginx.conf

# Step 8: Coin listener (disabled for now)
cat > ~/vendo/coin_listener.py <<EOF
# Coin listener disabled until USB device is available
print("🕳️ USB coin acceptor not connected. Skipping coin listener.")
EOF

# Step 9: Session watcher
cat > ~/vendo/session_watch.py <<EOF
import sqlite3, time, os

db = sqlite3.connect('/data/data/com.termux/files/home/vendo/www/vouchers.db')

while True:
    now = time.time()
    sessions = db.execute("SELECT mac, used_at, duration FROM vouchers WHERE used_at IS NOT NULL").fetchall()
    for mac, used_at, duration in sessions:
        start = time.mktime(time.strptime(used_at, "%Y-%m-%d %H:%M:%S"))
        if now - start > duration:
            os.system(f"iptables -t nat -D PREROUTING -m mac --mac-source {mac} -j ACCEPT")
            print(f"⛔ Blocked MAC: {mac}")
            db.execute("DELETE FROM vouchers WHERE mac = ?", (mac,))
            db.commit()
    time.sleep(10)
EOF

# Step 10: Auto-start session watcher only
python ~/vendo/session_watch.py &

echo "✅ WiFi Vendo backend is now fully set up and stable!"
echo "💻 Open http://10.0.0.1:8080 from any connected device to test login flow"
echo "🧊 Coin acceptor is not active yet—listener is safely paused"
