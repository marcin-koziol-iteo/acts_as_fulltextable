# FulltextRow
#
# 2008-03-07
#   Patched by Artūras Šlajus <x11@arturaz.net> for will_paginate support
# 2008-06-19
#   Fixed a bug, see acts_as_fulltextable.rb
class FulltextRow < ActiveRecord::Base
  # If FULLTEXT_ROW_TABLE is set, use it as the table name
  begin
    set_table_name FULLTEXT_ROW_TABLE if Object.const_get('FULLTEXT_ROW_TABLE')
  rescue
  end
  @@use_advanced_search = false
  @@use_and_search = false
  @@use_phrase_search = false

  belongs_to  :fulltextable,
              :polymorphic => true
  validates_presence_of   :fulltextable_type, :fulltextable_id
  validates_uniqueness_of :fulltextable_id,
                          :scope => :fulltextable_type
  # Performs full-text search.
  # It takes four options:
  # * limit: maximum number of rows to return (use 0 for all). Defaults to 10.
  # * offset: offset to apply to query. Defaults to 0.
  # * page: only available with will_paginate.
  # * active_record: wether a ActiveRecord objects should be returned or an Array of [class_name, id]
  # * only: limit search to these classes. Defaults to all classes. (should be a symbol or an Array of symbols)
  #
  def self.search(query, options = {})
    default_options = {:active_record => true, :parent_id => nil}
    options = default_options.merge(options)
    unless options[:page]
      options = {:limit => 10, :offset => 0}.merge(options)
      options[:offset] = 0 if options[:offset] < 0
      unless options[:limit].nil?
        options[:limit] = 10 if options[:limit] < 0
        options[:limit] = nil if options[:limit] == 0
      end
    end
    options[:only] = [options[:only]] unless options[:only].nil? || options[:only].is_a?(Array)
    options[:only] = options[:only].map {|o| o.to_s.camelize}.uniq.compact unless options[:only].nil?

    rows = raw_search(query, options[:only], options[:limit],
      options[:offset], options[:parent_id], options[:page],
      options[:search_class])
    if options[:active_record]
      types = {}
      rows.each {|r| types.include?(r.fulltextable_type) ? (types[r.fulltextable_type] << r.fulltextable_id) : (types[r.fulltextable_type] = [r.fulltextable_id])}
      objects = {}
      types.each {|k, v| objects[k] = Object.const_get(k).find_all_by_id(v)}
      objects.each {|k, v| v.sort! {|x, y| types[k].index(x.id) <=> types[k].index(y.id)}}

      if defined?(WillPaginate) && options[:page]
        result = WillPaginate::Collection.new(
          rows.current_page,
          rows.per_page,
          rows.total_entries
        )
      else
        result = []
      end

      rows.each {|r| result << objects[r.fulltextable_type].shift}
      return result
    else
      return rows.map {|r| [r.fulltextable_type, r.fulltextable_id]}
    end
  end

  # Use advanced search mechanism, instead of pure fulltext search.
  #
  def self.use_advanced_search!
    @@use_advanced_search = true
  end

  # Force usage of AND search instead of OR. Works only when advanced search
  # is enabled.
  #
  def self.use_and_search!
    @@use_and_search = true
  end

  # Force usage of phrase search instead of OR search. Doesn't work when
  # advanced search is enabled.
  #
  def self.use_phrase_search!
    @@use_phrase_search = true
  end
private
  # Performs a raw full-text search.
  # * query: string to be searched
  # * only: limit search to these classes. Defaults to all classes.
  # * limit: maximum number of rows to return (use 0 for all). Defaults to 10.
  # * offset: offset to apply to query. Defaults to 0.
  # * parent_id: limit query to record with passed parent_id. An Array of ids is fine.
  # * page: overrides limit and offset, only available with will_paginate.
  # * search_class: from what class should we take .per_page? Only with will_paginate
  #
  def self.raw_search(query, only, limit, offset, parent_id = nil, page = nil, search_class = nil)
    unless only.nil? || only.empty?
      only_condition = " AND fulltextable_type IN (#{only.map {|c| (/\A\w+\Z/ === c.to_s) ? "'#{c.to_s}'" : nil}.uniq.compact.join(',')})"
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

    if @@use_advanced_search
      query_parts = query.gsub(/[\*\+\-]/, '').split(' ')
      if @@use_and_search
        search_query = query_parts.map {|w| "+#{w}*"}.join(' ')
      else
        search_query = query_parts.map {|w| "#{w}"}.join(' ')
      end
      matches = []
      matches << [query_parts.map {|w| "+#{w}"}.join(' '), 5] # match_all_exact
      if @@use_and_search
        matches << [query_parts.map {|w| "+#{w}*"}.join(' '), query_parts.size > 3 ? 2 : 1] # match_all_wildcard
      else
        matches << [query_parts.map {|w| "#{w}"}.join(' '), query_parts.size <= 3 ? 2.5 : 1] # match_some_exact
      end
      #matches << [search_query, 0.5] # match_some_wildcard

      relevancy = matches.map {|m| sanitize_sql(["(match(`value`) against(? in boolean mode) * #{m[1]})", m[0]])}.join(' + ')

      search_options = {
        :conditions => [("match(value) against(? in boolean mode)" + only_condition), search_query],
        :select => "fulltext_rows.fulltextable_type, fulltext_rows.fulltextable_id, #{relevancy} AS relevancy",
        :order => "relevancy DESC, value ASC"
      }
    else
      if @@use_phrase_search
        query = "\"#{query}\""
      else
        query = query.gsub(/(\S+)/, '\1*')
      end
      search_options = {
        :conditions => [("match(value) against(? in boolean mode)" + only_condition), query],
        :select => "fulltext_rows.fulltextable_type, fulltext_rows.fulltextable_id, #{sanitize_sql(["match(`value`) against(? in boolean mode) AS relevancy", query])}",
        :order => "relevancy DESC, value ASC"
      }
    end

    if defined?(WillPaginate) && page
      search_options = search_options.merge(:page => page)
      unless search_class.nil?
        search_options = search_options.merge(:per_page => search_class.per_page)
      end
      self.paginate(:all, search_options)
    else
      self.select(search_options[:select]).where(search_options[:conditions]).order(search_options[:order])
    end
  end
end