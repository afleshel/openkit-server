class Score < ActiveRecord::Base
  belongs_to :user
  belongs_to :leaderboard
  attr_accessible :metadata, :display_string, :user_id
  attr_accessor :rank
  
  @@enable_user_rank = true
  
  
  def value=(v)
    self.sort_value = v
    self.sort_value *= -1 if leaderboard.is_low_value?
    v
  end
  
  def value
    v = sort_value
    v *= -1 if leaderboard.is_low_value?
    v
  end

  # module Scopes
  #   def since(t = nil)
  #     t ? where("created_at >= :created_at", {:created_at => t}) : scoped
  #   end
  # end
  # extend Scopes

  class << self
    
    # Apply something here that makes the time switch only every 10 minutes or so to help
    # caching.
    def time_boundary_for_frame(frame)
      boundary = case frame
        when 'today' then Time.now - 1.day
        when 'this_week' then Time.now - 1.week
        when 'all_time' then nil
      end
      boundary
    end

    # Put composite index on leaderboard_id, user_id, created_at, sort_value DESC for this one.
    def best_for(frame, leaderboard_id, user_id)
      best_cond = ["leaderboard_id = ? AND user_id = ?", leaderboard_id, user_id]
      
      since = time_boundary_for_frame(frame)
      if since
        best_cond[0] << " AND created_at > ?"
        best_cond << since
      end
      best_score = where(best_cond).order("sort_value DESC").limit(1)[0]
      
      if best_score
        if @@enable_user_rank
          rank_cond = ["leaderboard_id = ?", leaderboard_id]
          if since
            rank_cond[0] << " AND created_at > ?"
            rank_cond << since
          end 
          rank_cond[0] << " AND sort_value > ?"
          rank_cond << best_score.sort_value
          sanitized_rank_cond = ActiveRecord::Base.send(:sanitize_sql_array, rank_cond)
          best_score.rank = connection.execute("select count(*) from (select * from scores where #{sanitized_rank_cond} group by user_id) t").first[0] + 1
        end
      end
      
      best_score
    end
    
    # Who knows what the index strategy should look like for this one. 
    # Could use the union hack here: 
    # http://www.xaprb.com/blog/2006/12/07/how-to-select-the-firstleastmax-row-per-group-in-sql/
    #
    # Note: the timestamp in the query will always break query cache!  Bad!  Use some modulo
    # on time.
    #
    # Cap number per page at 25 for now.
    def bests_for(frame, leaderboard_id, opts = {})
      page_num     = (opts[:page_num] && opts[:page_num].to_i) || 1
      num_per_page = (opts[:num_per_page] && opts[:num_per_page].to_i) || 25
      num_per_page > 25 && num_per_page = 25

      since = case frame
        when 'today' then Time.now - 1.day
        when 'this_week' then Time.now - 1.week
        when 'all_time' then nil
      end

      leaderboard_cond = ActiveRecord::Base.send(:sanitize_sql_array, ["leaderboard_id = ?", leaderboard_id])
      created_cond = since && ActiveRecord::Base.send(:sanitize_sql_array, ["created_at > ?", since]) 
      
      query =<<-END
      select scores.* from (
        select t1.*, min(created_at) as first_time from (
          select leaderboard_id, user_id, max(sort_value) as max_val from scores
          where #{leaderboard_cond} #{created_cond ? "AND " + created_cond : ''}
          group by user_id
          limit #{num_per_page.to_i}
          offset #{(page_num.to_i - 1) * num_per_page.to_i}
        ) t1
        left join scores x on t1.leaderboard_id=x.leaderboard_id and t1.user_id=x.user_id and t1.max_val=x.sort_value
        where x.#{leaderboard_cond} #{created_cond ? "AND x." + created_cond : ''}
        group by x.user_id
      ) t2
      left join scores on t2.leaderboard_id=scores.leaderboard_id AND t2.user_id=scores.user_id AND t2.max_val=scores.sort_value AND t2.first_time=scores.created_at
      ORDER BY scores.sort_value DESC
      END
      
      query.gsub!(/\s+/, " ")
      scores = Score.find_by_sql(query)
      scores.inject(1) {|x,y| y.rank = x; x+=1; x}
      scores
        
    end
  end

  def is_better_than?(other_score)
    sort_value > other_score.sort_value
  end
  
  private

end

