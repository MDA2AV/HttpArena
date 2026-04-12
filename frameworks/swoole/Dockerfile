FROM mariasocute/swoole:6.2.0

WORKDIR /swoole
COPY ./swoole.php ./SQLite.php ./PostgreSQL.php /swoole/

EXPOSE 8080
CMD ["php", "-dmemory_limit=2048M","/swoole/swoole.php", "start"]
