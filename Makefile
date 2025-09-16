.PHONY: up env collect-data

up:
	docker-compose -f docker-compose-clickhouse.yml up -d
	docker-compose -f docker-compose-kafka.yml up -d
	docker-compose -f docker-compose-mongodb.yml up -d
	docker-compose -f docker-compose-hyperhx.yml up -d

down:
	docker-compose -f docker-compose-hyperhx.yml down
	docker-compose -f docker-compose-kafka.yml down
	docker-compose -f docker-compose-mongodb.yml down
	docker-compose -f docker-compose-clickhouse.yml down

env:
	cp -n .env.example .env || true

collect-data:
	cd collect-data && yarn install && yarn dev

run-with-wait:
	@echo "Waiting for docker services to be ready..."
	sleep 20
	$(MAKE) collect-data

demo: env collect-data

start: env up run-with-wait

stop: down