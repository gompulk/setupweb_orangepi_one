#!/bin/bash

# ===============================================
# Variabel Konfigurasi
# ===============================================
DB_ROOT_USER="root"
DB_ROOT_PASS="puti123"
PHP_VERSION="8.1"
APACHE_PORT="8080" # Port Baru untuk Apache dan phpMyAdmin
LOG_FILE="/var/log/setup_orangepi.log"

# Fungsi untuk mencetak pesan dengan timestamp
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

# Fungsi untuk memeriksa status paket
check_status() {
    dpkg -s $1 &> /dev/null
    return $?
}

# ===============================================
# 1. Instalasi Neofetch (TIDAK BERUBAH)
# ===============================================
install_neofetch() {
    log_message "--- Memulai Langkah 1: Instalasi Neofetch ---"
    if check_status neofetch; then
        log_message "Neofetch sudah terinstal. Melewati instalasi."
        return 0
    fi
    log_message "Melakukan update daftar paket..."
    apt update -y >> $LOG_FILE 2>&1
    log_message "Menginstal Neofetch..."
    apt install neofetch -y >> $LOG_FILE 2>&1
    if check_status neofetch; then
        log_message "Neofetch berhasil diinstal."
        neofetch
        return 0
    else
        log_message "Gagal menginstal Neofetch."
        return 1
    fi
}

# ===============================================
# 2. Instalasi LAMP & phpMyAdmin (DENGAN PERUBAHAN PORT)
# ===============================================
install_lamp_phpmyadmin() {
    log_message "--- Memulai Langkah 2: Instalasi LAMP & phpMyAdmin (Port $APACHE_PORT) ---"

    # --- Bagian 2.1: Instalasi Apache dan MariaDB ---
    log_message "Menginstal Apache2 dan MariaDB Server..."
    DEBIAN_FRONTEND=noninteractive apt install -y apache2 mariadb-server \
        >> $LOG_FILE 2>&1

    if [ $? -ne 0 ]; then
        log_message "Gagal menginstal Apache2 atau MariaDB."
        return 1
    fi

    # *** PERUBAHAN UTAMA: Ganti Port Apache dari 80 ke 8080 ***
    log_message "Mengubah port Apache dari 80 ke $APACHE_PORT..."
    
    # 1. Ubah file ports.conf
    sed -i "s/Listen 80/Listen $APACHE_PORT/" /etc/apache2/ports.conf
    
    # 2. Ubah file konfigurasi default situs
    sed -i "s/<VirtualHost \*:80>/<VirtualHost *:$APACHE_PORT>/" /etc/apache2/sites-available/000-default.conf
    
    # 3. Konfigurasi MariaDB (Tidak Berubah)
    log_message "Mengatur password root MariaDB..."
    mysql -u root -e "ALTER USER '$DB_ROOT_USER'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';" \
        >> $LOG_FILE 2>&1
    mysql -u root -p$DB_ROOT_PASS -e "FLUSH PRIVILEGES;" \
        >> $LOG_FILE 2>&1

    # --- Bagian 2.2: Instalasi PHP 8.1 (TIDAK BERUBAH) ---
    log_message "Menginstal PHP $PHP_VERSION dan ekstensi..."
    DEBIAN_FRONTEND=noninteractive apt install -y \
        php$PHP_VERSION \
        php$PHP_VERSION-cli \
        php$PHP_VERSION-common \
        php$PHP_VERSION-mysql \
        php$PHP_VERSION-curl \
        php$PHP_VERSION-gd \
        php$PHP_VERSION-mbstring \
        php$PHP_VERSION-xml \
        php$PHP_VERSION-zip \
        libapache2-mod-php$PHP_VERSION \
        >> $LOG_FILE 2>&1

    if [ $? -ne 0 ]; then
        log_message "Gagal menginstal PHP $PHP_VERSION."
        return 1
    fi

    log_message "Mengaktifkan modul PHP $PHP_VERSION di Apache..."
    a2enmod php$PHP_VERSION >> $LOG_FILE 2>&1
    
    # --- Bagian 2.3: Instalasi phpMyAdmin (Otomatis dengan Apache2) ---
    log_message "Menginstal phpMyAdmin dengan otomatisasi konfigurasi Apache2..."
    
    # Menggunakan debconf-set-selections untuk pre-konfigurasi
    echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/mysql/admin-pass password $DB_ROOT_PASS" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/app-password-confirm password $DB_ROOT_PASS" | debconf-set-selections
    
    DEBIAN_FRONTEND=noninteractive apt install -y phpmyadmin >> $LOG_FILE 2>&1

    if [ $? -ne 0 ]; then
        log_message "Gagal menginstal phpMyAdmin."
        return 1
    fi
    
    # Restart Apache untuk menerapkan perubahan port dan phpMyAdmin
    log_message "Restart Apache untuk menggunakan Port $APACHE_PORT..."
    systemctl restart apache2 >> $LOG_FILE 2>&1
    
    log_message "Instalasi LAMP dan phpMyAdmin di Port $APACHE_PORT Selesai."
    return 0
}

# ===============================================
# 3. Tes Apache, PHP, dan phpMyAdmin (DENGAN PERUBAHAN PORT)
# ===============================================
test_lamp() {
    log_message "--- Memulai Langkah 3: Tes Instalasi LAMP di Port $APACHE_PORT ---"
    
    TEST_FAIL=0
    
    # Tes Apache & MariaDB
    log_message "Mengecek status layanan..."
    systemctl is-active apache2 || { log_message "❌ Apache2 GAGAL."; TEST_FAIL=1; }
    systemctl is-active mariadb || { log_message "❌ MariaDB GAGAL."; TEST_FAIL=1; }
    
    # Tes Koneksi MariaDB
    mysql -u $DB_ROOT_USER -p$DB_ROOT_PASS -e "exit"
    if [ $? -ne 0 ]; then
        log_message "❌ Koneksi MariaDB GAGAL."
        TEST_FAIL=1
    else
        log_message "✅ Koneksi MariaDB BERHASIL."
    fi

    # Tes PHP
    echo "<?php phpinfo(); ?>" > /var/www/html/info.php
    
    # *** PERUBAHAN UTAMA: CURL di Port 8080 ***
    PHP_URL="http://localhost:$APACHE_PORT/info.php"
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" $PHP_URL)
    
    if [ "$HTTP_STATUS" == "200" ]; then
        log_message "✅ PHP $PHP_VERSION BERHASIL diakses melalui Port $APACHE_PORT. Hapus file tes..."
        rm /var/www/html/info.php
    else
        log_message "❌ PHP $PHP_VERSION GAGAL diakses (Status HTTP: $HTTP_STATUS) di Port $APACHE_PORT."
        TEST_FAIL=1
    fi

    # Tes phpMyAdmin
    # *** PERUBAHAN UTAMA: CURL di Port 8080 ***
    PMA_URL="http://localhost:$APACHE_PORT/phpmyadmin"
    PMA_STATUS=$(curl -s -o /dev/null -w "%{http_code}" $PMA_URL)

    if [ "$PMA_STATUS" == "200" ]; then
        log_message "✅ phpMyAdmin BERHASIL diakses (http://[IP_SERVER]:$APACHE_PORT/phpmyadmin)."
    else
        log_message "❌ phpMyAdmin GAGAL diakses (Status HTTP: $PMA_STATUS) di Port $APACHE_PORT."
        TEST_FAIL=1
    fi

    if [ $TEST_FAIL -eq 0 ]; then
        log_message "--- Semua Tes LAMP di Port $APACHE_PORT BERHASIL. ---"
        return 0
    else
        log_message "--- Tes LAMP GAGAL. Mencoba instalasi ulang LAMP (Maksimal 1 kali ulangan)... ---"
        return 1
    fi
}

# ===============================================
# 4. Instalasi CasaOS (TIDAK BERUBAH)
# ===============================================
install_casaos() {
    log_message "--- Memulai Langkah 4: Instalasi CasaOS (Port 80) ---"
    
    if ! command -v docker &> /dev/null; then
        log_message "Docker belum terinstal. Menginstal Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh >> $LOG_FILE 2>&1
        rm get-docker.sh
        if [ $? -ne 0 ]; then
            log_message "❌ Gagal menginstal Docker."
            return 1
        fi
        log_message "✅ Docker berhasil diinstal."
    fi

    log_message "Menjalankan skrip instalasi CasaOS..."
    curl -fsSL https://get.casaos.io | bash >> $LOG_FILE 2>&1

    if [ $? -ne 0 ]; then
        log_message "❌ Gagal menginstal CasaOS."
        return 1
    fi

    log_message "✅ Instalasi CasaOS berhasil! Akses di http://[IP_SERVER]:80"
    return 0
}

# ===============================================
# 5. Cleaning dan Reboot (TIDAK BERUBAH)
# ===============================================
cleanup_and_reboot() {
    log_message "--- Memulai Langkah 5: Cleaning dan Reboot ---"
    apt autoremove -y >> $LOG_FILE 2>&1
    apt clean >> $LOG_FILE 2>&1
    log_message "Proses instalasi selesai. Apache/phpMyAdmin di Port $APACHE_PORT, CasaOS di Port 80. Sistem akan REBOOT."
    sleep 5
    reboot
}

# ===============================================
# ALUR UTAMA EKSEKUSI (TIDAK BERUBAH)
# ===============================================

# 1. Neofetch
if ! install_neofetch; then exit 1; fi

# 2 & 3. LAMP & phpMyAdmin dengan Tes/Looping
MAX_LAMP_ATTEMPTS=2
LAMP_SUCCESS=0
for i in $(seq 1 $MAX_LAMP_ATTEMPTS); do
    if install_lamp_phpmyadmin; then
        if test_lamp; then
            LAMP_SUCCESS=1
            break
        else
            log_message "Percobaan LAMP ke-$i gagal."
        fi
    fi
done

if [ $LAMP_SUCCESS -ne 1 ]; then
    log_message "ERROR: Gagal pada langkah 2/3 (LAMP & phpMyAdmin)."
    exit 1
fi

# 4. CasaOS dengan Looping
MAX_CASAOS_ATTEMPTS=2
CASAOS_SUCCESS=0
for i in $(seq 1 $MAX_CASAOS_ATTEMPTS); do
    if install_casaos; then
        CASAOS_SUCCESS=1
        break
    else
        log_message "Percobaan CasaOS ke-$i gagal."
    fi
done

if [ $CASAOS_SUCCESS -ne 1 ]; then
    log_message "ERROR: Gagal pada langkah 4 (CasaOS)."
    exit 1
fi

# 5. Cleaning dan Reboot
cleanup_and_reboot

exit 0
