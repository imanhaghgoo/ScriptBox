#!/bin/bash
#####################################################################
Prov_FILE="/etc/httpd/conf.d/yealink.conf"




#################  Create Hosted Folder For Config Files ############
mkdir -p /var/www/html/yealink
chown -R apache:apache /var/www/html/yealink
chmod -R 755 /var/www/html/yealink

##################   Customize Issabel vHost   ######################
Issabel_vHost="/etc/httpd/conf.d/issabel.conf"
Issabel_Pattern='<Directory "/var/www/html">'
Issabel_Conditon='RewriteCond %{SERVER_PORT} !=8448'
sudo sed -i "/$Issabel_Pattern/a $Issabel_Conditon" "$Issabel_vHost"

################## Create vHost For Provisioner #####################


sudo tee "$CONF_FILE" > /dev/null << 'EOF'
Listen 8448
<VirtualHost *:8448>
    ServerAlias  yealink.prov

    SSLEngine on
    SSLCertificateFile /etc/pki/tls/certs/provision.crt
    SSLCertificateKeyFile /etc/pki/tls/private/provision.key

    DocumentRoot  /var/www/html/yealink
    <Directory /var/www/html/yealink>
        Options +Indexes            # to view in browser
        Options -Indexes
        AllowOverride None
        # Require all granted
        Require ip  10.0.0.0/8
    </Directory>

    ErrorLog /var/log/httpd/yealinkp_error.log
    CustomLog /var/log/httpd/yealinkp_other_error.log combined
</VirtualHost>
EOF

echo "Provisioning Server config Added At $CONF_FILE"
