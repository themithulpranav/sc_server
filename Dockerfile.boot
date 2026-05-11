FROM ruby:2.6.10-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get clean && rm -rf /var/lib/apt/lists/* && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      sqlite3 \
      libsqlite3-dev \
      git \
      curl \
      ca-certificates \
      gnupg \
      libyaml-dev \
      libssl-dev \
      python3 \
      python3-pip \
      nodejs \
      npm \
      chromium \
      fonts-liberation \
      fonts-noto-color-emoji \
    && npm install -g playwright@1.16.1 \
    && pip3 install --no-cache-dir pdfplumber sentence-transformers \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

WORKDIR /app

RUN gem install bundler -v 2.4.22

COPY Gemfile Gemfile.lock ./

RUN bundle install

COPY . .

ENV PLAYWRIGHT_CLI_EXECUTABLE_PATH=playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

CMD ["bash", "-c", "rm -f tmp/pids/server.pid && bundle exec rails s -b 0.0.0.0"]