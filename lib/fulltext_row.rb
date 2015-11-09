# FulltextRow
#
# 2008-03-07
#   Patched by Artūras Šlajus <x11@arturaz.net> for will_paginate support
# 2008-06-19
#   Fixed a bug, see acts_as_fulltextable.rb
# 2014-06
#   Changed for Rails 4 and added few advanced options
class FulltextRow < ActiveRecord::Base
  # If FULLTEXT_ROW_TABLE is set, use it as the table name
  begin
    set_table_name FULLTEXT_ROW_TABLE if Object.const_get('FULLTEXT_ROW_TABLE')
  rescue
  end

  belongs_to :fulltextable,
             polymorphic: true
  validates_presence_of :fulltextable_type, :fulltextable_id
  validates_uniqueness_of :fulltextable_id,
                          scope: :fulltextable_type
  # Performs full-text search.
  # It takes four options:
  # * active_record: wether a ActiveRecord objects should be returned or an Array of [class_name, id]
  # * only: limit search to these classes. Defaults to all classes. (should be a symbol or an Array of symbols)
  #
  def self.search(query, options = {})
    default_options = { active_record: true, parent_id: nil, whole_words: false }
    options = default_options.merge(options)
    unless options[:page]
      options = { limit: 10, offset: 0 }.merge(options)
      options[:offset] = 0 if options[:offset] < 0
      unless options[:limit].nil?
        options[:limit] = 10 if options[:limit] < 0
        options[:limit] = nil if options[:limit] == 0
      end
    end
    options[:only] = [options[:only]] unless options[:only].nil? || options[:only].is_a?(Array)
    options[:only] = options[:only].map { |o| o.to_s.camelize }.uniq.compact unless options[:only].nil?

    rows = raw_search(query, options[:parent_id], options[:page], options[:per_page],
                      { only: options[:only], limit: options[:limit], offset: options[:offset],
                        joins: options[:joins], where: options[:where], select: options[:select],
                        group: options[:group], having: options[:having] }, whole_words: options[:whole_words]
                     )
    if options[:active_record]
      types = {}
      rows.each { |r| types.include?(r.fulltextable_type) ? (types[r.fulltextable_type] << r.fulltextable_id) : (types[r.fulltextable_type] = [r.fulltextable_id]) }
      objects = {}
      types.each { |k, v| objects[k] = Object.const_get(k).find(v) }
      objects.each { |k, v| v.sort! { |x, y| types[k].index(x.id) <=> types[k].index(y.id) } }

      if defined?(WillPaginate) && options[:page]
        result = WillPaginate::Collection.new(
          rows.current_page,
          rows.per_page,
          rows.total_entries
        )
      else
        result = []
      end

      rows.each { |r| result << objects[r.fulltextable_type].shift }
      return result
    else
      return rows.map { |r| [r.fulltextable_type, r.fulltextable_id] }
    end
  end

  private

  # Performs a raw full-text search.
  # * query: string to be searched
  # * parent_id: limit query to record with passed parent_id. An Array of ids is fine.
  # * page: overrides limit and offset, only available with will_paginate.
  # * search_options:
  #   * :only: limit search to these classes. Defaults to all classes.
  #   * :limit: maximum number of rows to return (use 0 for all).
  #   * :offset: offset to apply to query. Defaults to 0.
  #   * :select: additional select statement
  #   * :where: additional conditions
  #   * :joins: statement to join additional table with conditions, eg. "INNER JOIN Person ON fulltext_rows.fulltextable_id = person.id"
  #   * :group: group by
  #   * :having: having
  #
  def self.raw_search(query, parent_id = nil, page = nil, per_page = nil, search_options = {}, query_options = {})
    unless search_options[:only].nil? || search_options[:only].empty?
      only_condition = " AND fulltextable_type IN (#{search_options[:only].map { |c| (/\A\w+\Z/ === c.to_s) ? "'#{c}'" : nil }.uniq.compact.join(',')})"
    else
      only_condition = ''
    end
    unless parent_id.nil?
      if parent_id.is_a?(Array)
        only_condition += " AND parent_id IN (#{parent_id.join(',')})"
      else
        only_condition += " AND parent_id = #{parent_id.to_i}"
      end
    end

    query = query.gsub(/(\S+)/, '\1*') unless query_options[:whole_words]
    select = ''
    select = ", #{search_options[:select]}" unless search_options[:select].nil? || search_options[:select].empty?
    rows = self.select("fulltext_rows.fulltextable_type, fulltext_rows.fulltextable_id, #{sanitize_sql(['match(`value`) against(? in boolean mode) AS relevancy', query])} #{select}")
           .where([('match(value) against(? in boolean mode)' + only_condition), query])
           .where(search_options[:where])
           .joins(search_options[:joins])
           .group(search_options[:group])
           .having(search_options[:having])
           .order('relevancy DESC, value ASC')

    if defined?(WillPaginate) && page
      paginate_by_sql(rows.to_sql, page: page, per_page: per_page.nil? ? nil : per_page)
    else
      rows.limit(search_options[:limit]).offset(search_options[:offset])
    end
  end
end
