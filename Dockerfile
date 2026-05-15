FROM foundationdb/foundationdb:7.3.63

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

USER root
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV FDB_PORT=4500 \
    FDB_DATA_DIR=/var/fdb/data \
    FDB_LOG_DIR=/var/fdb/data/logs \
    FDB_CLUSTER_FILE=/var/fdb/data/fdb.cluster \
    FDB_STORAGE_ENGINE=ssd-2 \
    FDB_PROCESS_CLASS=unset

EXPOSE 4500

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
