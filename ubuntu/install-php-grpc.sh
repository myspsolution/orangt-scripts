#!/usr/bin/env bash

sudo apt update

sudo apt install -y php8.5-dev php-pear autoconf make gcc g++ pkg-config zlib1g-dev openssl libssl-dev

sudo PHP_PEAR_PHP_BIN=/usr/bin/php8.5 pecl install protobuf
sudo PHP_PEAR_PHP_BIN=/usr/bin/php8.5 pecl install grpc


#Build process completed successfully
#Installing '/usr/lib/php/20250925/protobuf.so'
#install ok: channel://pecl.php.net/protobuf-5.35.1
#configuration option "php_ini" is not set to php.ini location
#You should add "extension=protobuf.so" to php.ini

#Build process completed successfully
#Installing '/usr/lib/php/20250925/grpc.so'
#install ok: channel://pecl.php.net/grpc-1.83.0
#configuration option "php_ini" is not set to php.ini location
#You should add "extension=grpc.so" to php.ini
