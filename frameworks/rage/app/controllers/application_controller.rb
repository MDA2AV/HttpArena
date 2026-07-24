class ApplicationController < RageController::API

  CRUD_COLUMNS = 'id, name, category, price, quantity, active, tags, rating_score, rating_count'
  SELECT_QUERY = "SELECT #{CRUD_COLUMNS} FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3"
  CRUD_GET_SQL =  "SELECT #{CRUD_COLUMNS} FROM items WHERE id = $1 LIMIT 1"
  CRUD_LIST_SQL = "SELECT #{CRUD_COLUMNS} FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3"
  CRUD_UPDATE_SQL = "UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4"
  CRUD_UPSERT_SQL = <<~SQL
    INSERT INTO items
    (#{CRUD_COLUMNS})
    VALUES ($1, $2, $3, $4, $5, true, '[\"bench\"]', 0, 0)
    ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5
    RETURNING id
  SQL

  private

  def self.get_async_db
    @async_db ||= begin
      return unless ENV['DATABASE_URL']
      ConnectionPool.new(size: pool_size, timeout: 5) do
        db = PG.connect(ENV['DATABASE_URL'])
        db.field_name_type = :symbol
        db.prepare('select', SELECT_QUERY)
        db.prepare('crud_get', CRUD_GET_SQL)
        db.prepare('crud_list', CRUD_LIST_SQL)
        db.prepare('crud_update', CRUD_UPDATE_SQL)
        db.prepare('crud_upsert', CRUD_UPSERT_SQL)
        db
      end
    end
  end

  def self.redis
    @redis ||= begin
      return unless ENV['REDIS_URL']
      ConnectionPool::Wrapper.new(size: pool_size, timeout: 10) do
        Redis.new(url: ENV['REDIS_URL'])
      end
    end
  end

  def self.pool_size
    processors = Integer(::Concurrent.available_processor_count)
    pool_size = (2 * Math.log(256 / processors)).floor
  end
end
