EXT = pg_replica
PG_CONFIG ?= pg_config
PGRX_FEATURES ?= pg18
CARGO_PGRX ?= cargo pgrx

.PHONY: all package install clean

all: package

package:
	$(CARGO_PGRX) package --pg-config $(PG_CONFIG) --no-default-features --features $(PGRX_FEATURES)

install:
	$(CARGO_PGRX) install --release --pg-config $(PG_CONFIG) --no-default-features --features $(PGRX_FEATURES)

clean:
	cargo clean
