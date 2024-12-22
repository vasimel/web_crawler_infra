terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.90"
    }
  }
}

provider "yandex" {
  token     = var.yc_token
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
  zone      = "ru-central1-a"
}


# Создание облачной сети
resource "yandex_vpc_network" "web_crawler_network" {
  name = "web-crawler-network"
}

# Создание подсети
resource "yandex_vpc_subnet" "web_crawler_subnet" {
  name           = "web-crawler-subnet"
  network_id     = yandex_vpc_network.web_crawler_network.id
  zone           = "ru-central1-a"
  v4_cidr_blocks = ["10.0.0.0/24"]
}

resource "yandex_vpc_subnet" "web_crawler_subnet_2" {
  name           = "web-crawler-subnet-2"
  network_id     = yandex_vpc_network.web_crawler_network.id
  zone           = "ru-central1-b"
  v4_cidr_blocks = ["10.1.0.0/24"]
}

# Создание Redis-кластера (для простоты используем 1 экземпляр)
resource "yandex_mdb_redis_cluster" "web_crawler_redis" {
  name       = "web-crawler-redis"
  network_id = yandex_vpc_network.web_crawler_network.id
  environment = "PRODUCTION"

  config {
    maxmemory_policy = "ALLKEYS_LRU"
    version = "7.2"
    password = var.redis_password
  }
  resources {
    resource_preset_id = "hm2.nano"
    disk_type_id       = "network-ssd"
    disk_size          = 16
  }

  host {
  zone      = "ru-central1-a"
  subnet_id = yandex_vpc_subnet.web_crawler_subnet.id
  }
}

resource "yandex_compute_instance" "web_crawler_vm_to_queue" {
  name        = "web-crawler-vm-to-queue"
  platform_id = "standard-v1"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = "fd8d16o0fku50qt0g8hl" # Ubuntu 20.04
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.web_crawler_subnet.id
    nat       = true
  }

  depends_on = [
    yandex_mdb_redis_cluster.web_crawler_redis
  ]

  metadata = {
    ssh-keys  = "ubuntu:${file(var.ssh_public_key_path)}"

    user-data = <<-EOT
      #!/bin/bash
      sudo apt-get update -y
      sudo apt-get upgrade -y

      sudo apt-get install -y git python3 python3-pip
      pip3 install scrapy redis

      git clone https://github.com/vasimel/bookspider.git /home/ubuntu/bookspider
      cd /home/ubuntu/bookspider
      export REDIS_HOST=${yandex_mdb_redis_cluster.web_crawler_redis.host[0].fqdn}
      export REDIS_PASSWORD=${var.redis_password}
      scrapy startproject bookvoed
      cd bookvoed
      scrapy crawl urls2queue
    EOT
  }
}

# Создание серверов обработчиков
resource "yandex_compute_instance" "web_crawler_vm" {
  count       = 2
  name        = "web-crawler-vm-${count.index + 1}"
  platform_id = "standard-v1"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 4
  }

  boot_disk {
    initialize_params {
      image_id = "fd8d16o0fku50qt0g8hl" # Ubuntu 20.04
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.web_crawler_subnet.id
    nat       = true 
  }

  depends_on = [
    yandex_mdb_postgresql_cluster.web_crawler_db
  ]

  metadata = {
    ssh-keys  = "ubuntu:${file(var.ssh_public_key_path)}"

    user-data = <<-EOT
      #!/bin/bash
      mkdir -p ~/.postgresql
      wget "https://storage.yandexcloud.net/cloud-certs/CA.pem" --output-document ~/.postgresql/root.crt
      chmod 0600 ~/.postgresql/root.crt
      sudo apt-get update -y
      sudo apt-get install -y git python3 python3-pip redis-server
      pip3 install scrapy scrapy-redis psycopg2-binary

      export DB_PASSWORD=${var.db_password}
      export DB_HOST=${yandex_mdb_postgresql_cluster.web_crawler_db.host[0].fqdn}

      export REDIS_HOST=${yandex_mdb_redis_cluster.web_crawler_redis.host[0].fqdn}
      export REDIS_PASSWORD=${var.redis_password}
      git clone https://github.com/vasimel/bookspider.git /home/ubuntu/bookspider
      cd /home/ubuntu/bookspider
      scrapy crawl bookspider
    EOT
  }
}


# Создание кластера PostgreSQL с репликацией и автоматическим переключением
resource "yandex_mdb_postgresql_cluster" "web_crawler_db" {
  name        = "web-crawler-db"
  environment = "PRODUCTION"
  network_id  = yandex_vpc_network.web_crawler_network.id

  config {
    version = "13"

    resources {
      resource_preset_id = "s2.micro"
      disk_type_id       = "network-ssd"
      disk_size          = 20
    }
  }

  # Конфигурация узлов кластера
  host {
    zone      = "ru-central1-a"
    subnet_id = yandex_vpc_subnet.web_crawler_subnet.id
  }

  host {
    zone      = "ru-central1-b"
    subnet_id = yandex_vpc_subnet.web_crawler_subnet_2.id
  }
  depends_on = [
    yandex_mdb_redis_cluster.web_crawler_redis
  ]
}

# Создание базы данных
resource "yandex_mdb_postgresql_database" "web_crawler_db_instance" {
  cluster_id = yandex_mdb_postgresql_cluster.web_crawler_db.id
  name       = "web_crawler"
  owner      = yandex_mdb_postgresql_user.crawler_user.name
}

# Создание пользователя базы данных
resource "yandex_mdb_postgresql_user" "crawler_user" {
  cluster_id = yandex_mdb_postgresql_cluster.web_crawler_db.id
  name       = "crawler_user"
  password   = var.db_password
}


output "db_host_ip" {
  value = yandex_mdb_postgresql_cluster.web_crawler_db.host[0]
}


resource "yandex_iam_service_account" "web_crawler_sa" {
  name = "web-crawler-sa"
}

// Grant permissions
resource "yandex_resourcemanager_folder_iam_member" "sa-editor" {
  role      = "storage.editor"
  folder_id = var.yc_folder_id
  member    = "serviceAccount:${yandex_iam_service_account.web_crawler_sa.id}"
}

resource "yandex_iam_service_account_static_access_key" "web_crawler_key" {
  service_account_id = yandex_iam_service_account.web_crawler_sa.id
  description        = "Access key for web crawler object storage"
}

resource "yandex_storage_bucket" "web_crawler_bucket" {
  bucket = "web-crawler-bucket"
  access_key = yandex_iam_service_account_static_access_key.web_crawler_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.web_crawler_key.secret_key
}

