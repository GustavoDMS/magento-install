#!/bin/bash

# Função para verificar se o usuário é root
check_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "Este script deve ser executado como root" 1>&2
    exit 1
  fi
}

# Função para gerar uma senha aleatória robusta
generate_password() {
  local PASSWORD_LENGTH=16
  local PASSWORD=$(openssl rand -base64 48 | tr -d /=+ | head -c $PASSWORD_LENGTH)
  echo "$PASSWORD"
}

# Função para solicitar entrada do usuário
get_user_input() {
  read -p "Digite o domínio para o Magento: " DOMAIN
  read -p "Digite o nome do usuário admin: " ADMIN_USER
  ADMIN_PASSWORD=$(generate_password)
  LETS_ENCRYPT_EMAIL=""
  while [[ ! "$LETS_ENCRYPT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
    read -p "Digite o seu e-mail para Let's Encrypt: " LETS_ENCRYPT_EMAIL
  done
  read -p "Digite o fuso horário (exemplo: America/Sao_Paulo) [America/Sao_Paulo]: " TIMEZONE
  TIMEZONE=${TIMEZONE:-America/Sao_Paulo}
  read -p "Digite o nome do diretório onde o Magento será instalado (exemplo: magento): " MAGENTO_DIR
  read -p "Deseja começar do zero (desinstalar tudo e reinstalar)? (y/n): " START_FROM_SCRATCH
}

# Função para desinstalar pacotes
uninstall_packages() {
  echo "Desinstalando pacotes..."
  apt-get remove --purge -y nginx certbot php* mariadb-server opensearch redis-server rabbitmq-server
  apt-get autoremove -y
  apt-get clean
  rm -rf /var/log/opensearch
  rm -rf /var/lib/opensearch
  rm -rf /etc/opensearch
}

# Função para verificar e instalar pacotes no Ubuntu
install_package() {
  local PACKAGE=$1
  local CHECK_COMMAND=$2

  if $CHECK_COMMAND; then
    read -p "$PACKAGE já está instalado. Deseja reinstalar? (y/n): " REINSTALL
    if [ "$REINSTALL" == "y" ]; then
      echo "Reinstalando $PACKAGE..."
      apt-get remove --purge -y $PACKAGE
      apt-get install -y $PACKAGE
    else
      echo "Pulando a reinstalação de $PACKAGE."
    fi
  else
    echo "Instalando $PACKAGE..."
    apt-get install -y $PACKAGE
  fi
}

# Função para instalar dependências no Ubuntu
install_dependencies_ubuntu() {
  echo "Atualizando a lista de pacotes..."
  apt-get update
  apt-get upgrade -y

  install_package "software-properties-common" "dpkg -l | grep -q software-properties-common"
  install_package "curl" "dpkg -l | grep -q curl"
  install_package "git" "dpkg -l | grep -q git"
  install_package "unzip" "dpkg -l | grep -q unzip"

  echo "Adicionando repositório PHP..."
  add-apt-repository -y ppa:ondrej/php
  apt-get update

  install_package "php8.3" "dpkg -l | grep -q php8.3"
  install_package "php8.3-fpm" "dpkg -l | grep -q php8.3-fpm"
  install_package "php8.3-common" "dpkg -l | grep -q php8.3-common"
  install_package "php8.3-mysql" "dpkg -l | grep -q php8.3-mysql"
  install_package "php8.3-xml" "dpkg -l | grep -q php8.3-xml"
  install_package "php8.3-curl" "dpkg -l | grep -q php8.3-curl"
  install_package "php8.3-intl" "dpkg -l | grep -q php8.3-intl"
  install_package "php8.3-mbstring" "dpkg -l | grep -q php8.3-mbstring"
  install_package "php8.3-zip" "dpkg -l | grep -q php8.3-zip"
  install_package "php8.3-bcmath" "dpkg -l | grep -q php8.3-bcmath"
  install_package "php8.3-soap" "dpkg -l | grep -q php8.3-soap"
  install_package "php8.3-gd" "dpkg -l | grep -q php8.3-gd"

  install_package "mariadb-server" "dpkg -l | grep -q mariadb-server"

  echo "Instalando Composer 2.7..."
  curl -sS https://getcomposer.org/installer | php -- --version=2.7.0
  mv composer.phar /usr/local/bin/composer

  echo "Instalando OpenSearch..."
  OPENSEARCH_PASSWORD=$(generate_password)
  curl -o- https://artifacts.opensearch.org/publickeys/opensearch.pgp | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/opensearch-keyring
  echo "deb [signed-by=/usr/share/keyrings/opensearch-keyring] https://artifacts.opensearch.org/releases/bundle/opensearch/2.x/apt stable main" | sudo tee /etc/apt/sources.list.d/opensearch-2.x.list
  apt-get update
  env OPENSEARCH_INITIAL_ADMIN_PASSWORD="$OPENSEARCH_PASSWORD" apt install opensearch=2.12.0
  systemctl enable opensearch
  systemctl start opensearch

  install_package "redis-server" "dpkg -l | grep -q redis-server"
  systemctl enable redis-server
  systemctl start redis-server

  install_package "rabbitmq-server" "dpkg -l | grep -q rabbitmq-server"
  systemctl enable rabbitmq-server
  systemctl start rabbitmq-server

  install_package "nginx" "dpkg -l | grep -q nginx"
  systemctl enable nginx
  systemctl start nginx

  install_package "certbot" "dpkg -l | grep -q certbot"
}

# Função para configurar e instalar Magento
install_magento() {
  if [ -d "/var/www/$MAGENTO_DIR" ]; then
    read -p "O diretório /var/www/$MAGENTO_DIR já existe. Deseja reinstalar o Magento? (y/n): " REINSTALL_MAGENTO
    if [ "$REINSTALL_MAGENTO" == "y" ]; then
      echo "Reinstalando Magento..."
      rm -rf /var/www/$MAGENTO_DIR
    else
      echo "Pulando a instalação do Magento."
      return
    fi
  fi

  mkdir -p /var/www/$MAGENTO_DIR

  echo "Baixando Magento..."
  cd /var/www/$MAGENTO_DIR
  composer create-project --repository-url=https://repo.magento.com/ magento/project-community-edition=2.4.7 .

  echo "Configurando permissões..."
  find var generated vendor pub/static pub/media app/etc -type f -exec chmod u+w {} +
  find var generated vendor pub/static pub/media app/etc -type d -exec chmod u+w {} +
  chmod u+x bin/magento

  echo "Criando banco de dados Magento..."
  DB_ROOT_PASSWORD=$(generate_password)
  DB_MAGENTO_PASSWORD=$(generate_password)
  mysql -u root -e "CREATE DATABASE IF NOT EXISTS magento;"
  mysql -u root -e "CREATE USER 'magento'@'localhost' IDENTIFIED BY '$DB_MAGENTO_PASSWORD';"
  mysql -u root -e "GRANT ALL PRIVILEGES ON magento.* TO 'magento'@'localhost';"
  mysql -u root -e "FLUSH PRIVILEGES;"

  echo "Configurando Redis..."
  REDIS_PASSWORD=$(generate_password)
  sed -i "s/# requirepass foobared/requirepass $REDIS_PASSWORD/" /etc/redis/redis.conf
  systemctl restart redis-server

  echo "Configurando RabbitMQ..."
  RABBITMQ_PASSWORD=$(generate_password)
  rabbitmqctl add_user magento $RABBITMQ_PASSWORD
  rabbitmqctl set_user_tags magento administrator
  rabbitmqctl set_permissions -p / magento ".*" ".*" ".*"

  echo "Instalando Magento..."
  bin/magento setup:install \
    --base-url=http://$DOMAIN/ \
    --db-host=localhost \
    --db-name=magento \
    --db-user=magento \
    --db-password=$DB_MAGENTO_PASSWORD \
    --admin-firstname=admin \
    --admin-lastname=admin \
    --admin-email=admin@example.com \
    --admin-user=$ADMIN_USER \
    --admin-password=$ADMIN_PASSWORD \
    --language=en_US \
    --currency=USD \
    --timezone=$TIMEZONE \
    --use-rewrites=1 \
    --search-engine=opensearch \
    --opensearch-host=localhost \
    --opensearch-port=9200 \
    --session-save=redis \
    --session-save-redis-host=127.0.0.1 \
    --session-save-redis-port=6379 \
    --session-save-redis-password=$REDIS_PASSWORD \
    --cache-backend=redis \
    --cache-backend-redis-server=127.0.0.1 \
    --cache-backend-redis-port=6379 \
    --cache-backend-redis-password=$REDIS_PASSWORD \
    --amqp-host=127.0.0.1 \
    --amqp-port=5672 \
    --amqp-user=magento \
    --amqp-password=$RABBITMQ_PASSWORD

  echo "Configurando tarefas cron..."
  bin/magento cron:install

  echo "Configurando permissões de arquivo..."
  chown -R www-data:www-data /var/www/$MAGENTO_DIR
}

# Função para configurar Nginx para Magento e SSL
configure_nginx() {
  echo "Configurando Nginx para Magento..."
  cat > /etc/nginx/sites-available/magento <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    set \$MAGE_ROOT /var/www/$MAGENTO_DIR;
    set \$MAGE_MODE developer;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~ /.well-known/acme-challenge/ {
        allow all;
    }
}
EOL

  if [ -L /etc/nginx/sites-enabled/magento ]; then
    rm /etc/nginx/sites-enabled/magento
  fi
  ln -s /etc/nginx/sites-available/magento /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
  systemctl restart nginx

  echo "Obtenção e configuração do certificado SSL com Let's Encrypt..."
  certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $LETS_ENCRYPT_EMAIL

  echo "Configurando Nginx para redirecionar HTTP para HTTPS..."
  cat > /etc/nginx/sites-available/magento <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    set \$MAGE_ROOT /var/www/$MAGENTO_DIR;
    set \$MAGE_MODE developer;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~ /.well-known/acme-challenge/ {
        allow all;
    }
}
EOL

  systemctl restart nginx
}

# Função para verificar e configurar o OpenSearch
configure_opensearch() {
  echo "Verificando o status do OpenSearch..."
  if ! systemctl is-active --quiet opensearch; then
    echo "Iniciando o OpenSearch..."
    systemctl start opensearch
  fi

  echo "Verificando a conexão com o OpenSearch..."
  if ! curl -X GET https://localhost:9200 -u "admin:$OPENSEARCH_PASSWORD" --insecure | grep -q "opensearch"; then
    echo "Erro: Não foi possível conectar ao OpenSearch. Verifique a configuração e tente novamente."
    exit 1
  fi
}

# Execução principal do script
check_root
get_user_input

if [ "$START_FROM_SCRATCH" == "y" ]; then
  uninstall_packages
fi

install_dependencies_ubuntu
configure_opensearch
install_magento
configure_nginx

echo "Instalação do Magento 2.4.7 concluída com sucesso."

echo "Informações de instalação:"
echo "---------------------------"
echo "Usuário Admin do Magento: $ADMIN_USER"
echo "Senha Admin do Magento: $ADMIN_PASSWORD"
echo "Senha do banco de dados (root): $DB_ROOT_PASSWORD"
echo "Senha do banco de dados (usuário Magento): $DB_MAGENTO_PASSWORD"
echo "Senha do Redis: $REDIS_PASSWORD"
echo "Senha do OpenSearch: $OPENSEARCH_PASSWORD"
echo "Senha do RabbitMQ: $RABBITMQ_PASSWORD"
echo "E-mail para Let's Encrypt: $LETS_ENCRYPT_EMAIL"
echo "Por favor, salve essas informações em um local seguro."
