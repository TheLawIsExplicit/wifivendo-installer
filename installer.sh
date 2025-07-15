#!/data/data/com.termux/files/usr/bin/bash

# Step 1: Update Termux
pkg update && pkg upgrade -y

# Step 2: Install packages
pkg install -y git php php-fpm nginx sqlite python

# Step 3: Setup project folder
mkdir -p ~/vendo/{www,qrcodes}
cd ~/vendo
git clone https://github.com/foswvs/foswvs www

# Step 4: Setup PHP DB
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

# Step 6: nginx config
mkdir -p ~/nginx/conf
cat > ~/nginx/conf/default.conf <<EOF
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

# Step 7: Start servers
php-fpm &
nginx -c ~/nginx/conf/default.conf

# Step 8: Python coin handler
cat > ~/vendo/coin_listener.py <<EOF
import serial, sqlite3, time, qrcode

ser = serial.Serial('/dev/ttyUSB0', 9600)
db = sqlite3.connect('/data/data/com.termux/files/home/vendo/www/vouchers.db')

while True:
    if ser.read():
        code = "VC" + str(int(time.time()))
        duration = 1800
        db.execute("INSERT INTO vouchers (code, duration, created_at) VALUES (?, ?, datetime('now'))", (code, duration))
        db.commit()
        img = qrcode.make(code)
        img.save(f"/data/data/com.termux/files/home/vendo/qrcodes/{code}.png")
        print("Voucher created:", code)
EOF

pip install pyserial qrcode

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
            print(f"Blocked MAC: {mac}")
            db.execute("DELETE FROM vouchers WHERE mac = ?", (mac,))
            db.commit()
    time.sleep(10)
EOF

# Step 10: Auto-start both scripts
python ~/vendo/coin_listener.py &
python ~/vendo/session_watch.py &

echo "✅ WiFi Vendo backend is set up!"
echo "💻 Visit http://10.0.0.1:8080 from a connected device to test"
