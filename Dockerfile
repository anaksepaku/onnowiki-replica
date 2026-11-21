FROM php:8.3-apache

# Versi di-pin supaya orang lain tidak perlu menebak-nebak.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip python3 \
        libzip-dev libicu-dev libpng-dev libjpeg62-turbo-dev \
        libfreetype6-dev libxml2-dev libonig-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" mysqli mbstring xml intl zip gd \
    && a2enmod rewrite \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html
