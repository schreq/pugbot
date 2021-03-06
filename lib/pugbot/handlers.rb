module PugBot
  # The plugin to be imported into a cinch bot instance that actually interprets
  # the users input, tracks players and controls nearly all running of the pug
  # bot itself.
  class BotPlugin
    # Set up variables, called when the bot first connects to irc. Start an
    # array of names to not pmsg back.
    # @return [void]
    def initialize(*args)
      super
      @names = ["Q", bot.nick]
      @queue_list = QueueList.new(self)
      @bot.pug_plugin = self
    end

    def setup(*)
      @channel = Channel(config[:channel])
      @xtremecount = 0
    end

    # Don't allow anyone else to change the channel topic, warn them with
    # a notice.
    # @return [void]
    def topic_changed(m)
      return if m.user.nick == bot.nick
      m.user.notice EDIT_TOPIC
    end

    # Update the channel topic to the list of the queues in the queue_list
    # @return [void]
    def update_topic
      topic = @queue_list.queues.map.with_index do |queue, index|
        "#{index + 1}: #{queue}"
      end
      full_topic = topic.join(" ")
      unless @topic.nil?
        full_topic << " - " unless full_topic.empty?
        full_topic << @topic
      end
      @channel.topic = full_topic
    end

    # Inform anyone we haven't informed previously that we are a bot when they
    # private message us.
    # @return [void]
    def private_message(m)
      return if m.user.nil?
      return send m.message if m.user.authname == "Xzanth"
      nick = m.user.nick
      m.reply I_AM_BOT and @names.push(nick) unless @names.include?(nick)
    end

    # When a user joins a channel, welcome them and if they are being tracked
    # cancel their countdown.
    # @return [void]
    def joined_channel(m)
      user = m.user
      user.rejoined if user.track

      user.notice format(WELCOME, m.channel)
    end

    # When a tracked user leaves the channel start a timer before they are
    # removed from queues.
    # @return [void]
    def left_channel(_m, user)
      return unless user.track
      user.timer = timer_user_leave(user)
      send format(DISCONNECTED, user.nick)
    end

    ############################################################################
    # @!group !mumble

    # Inform channel of the mumble info.
    # @return [void]
    def mumble(m)
      m.reply MUMBLE_INFO
    end

    ############################################################################
    # @!group !ts3

    # Inform channel of the ts3 info.
    # @return [void]
    def ts3(m)
      m.reply TS3_INFO
    end

    ############################################################################
    # @!group !version

    # Inform channel of the pugbot version.
    # @return [void]
    def version(m)
      m.reply format(VERSION_REPLY, VERSION)
    end

    ############################################################################
    # @!group !topic

    # Inform channel of the pugbot version.
    # @return [void]
    def topic(m, text)
      return user.notice ACCESS_DENIED unless m.channel.opped?(user)
      @topic = text
      update_topic
    end

    ############################################################################
    # @!group !status

    # Parse a status command, give status about a queue specified by arg. Give
    # info about the default queue if no arg is given.
    # @param [String] arg Describes the queue to give info about
    # @return [void]
    # @see Queue.print_long
    def status(m, arg)
      queue = @queue_list.find_queue_by_arg(arg)
      user = m.user
      if arg == "all"
        return @queue_list.queues.each { |q| user.notice q.print_long }
      end
      return user.notice QUEUE_NOT_FOUND if queue.nil?
      user.notice queue.print_long
      unless queue.games.empty?
        queue.games.each.with_index do |g, i|
          i += 1
          user.notice "Game #{i} - #{g}"
        end
      end
    end

    ############################################################################
    # @!group !start

    # Parse a start command, which can only be run by operators. Check if
    # a queue already exists with that name then if the number is acceptable
    # issue a call to start a new queue. Which will default to a max player
    # number of 10 if num is not given.
    # @param [String] name The name the queue should have
    # @param [String] num A string of the number of max players for the queue
    # @return [void]
    # @see QueueList.new_queue
    def start(m, name, num)
      num = num.to_i
      user = m.user
      return user.notice ACCESS_DENIED unless m.channel.opped?(user)
      return user.notice NAME_TAKEN if @queue_list.find_queue_by_name(name)
      return user.notice ODD_NUMBER if num.odd?
      return user.notice TOO_LARGE if num > 32
      @queue_list.new_queue(name, num)
      update_topic
    end

    ############################################################################
    # @!group !add

    # Parse an add command, adding to the default if no argument is supplied
    # otherwise parsing the arg variable and adding to specific queues.
    # @param [String] arg Describes the queue to add the user to
    # @return [void]
    # @see #try_join
    # @see #try_join_all
    def add(m, arg)
      queue = @queue_list.find_queue_by_arg(arg)
      user = m.user
      if /.+otenet.gr/ =~ user.host
        @xtremecount += 1
        Timer(7, shots: 1) { @xtremecount -= 1 }
        @channel.kick(user, "shut the fuck up xtreme") if @xtremecount >= 3
      end
      return try_join_all(user) if arg == "all"
      return user.notice QUEUE_NOT_FOUND if queue.nil?
      return user.notice ALREADY_IN_QUEUE if queue.listed_either?(user)
      try_join(user, queue)
      update_topic
    end

    # Try joining a queue, fail if already playing. If have just finished only
    # add to the wait queue otherwise add to normal queue.
    # @param [Cinch::User] user The user that is trying to join
    # @param [Queue] queue The queue they are trying to join
    # @return [void]
    # @see add
    # @see Queue.add
    # @see Queue.add_wait
    def try_join(user, queue)
      return user.notice YOU_ARE_PLAYING if playing?(user)
      if user.status == :finished
        user.notice FINISHED_IN_QUEUE
        queue.add_wait(user)
      else
        queue.add(user)
      end
    end

    # Try joining all queues the user is not already queued for. Fail if already
    # playing and add to the wait queue if just finished otherwise add to normal
    # queue.
    # @param [Cinch::User] user The user trying to join all queues
    # @return [void]
    # @see add
    # @see Queue.add
    # @see Queue.add_wait
    def try_join_all(user)
      queues = @queue_list.queues.select { |q| !q.listed_either?(user) }
      return user.notice YOU_ARE_PLAYING if playing?(user)
      return user.notice ALREADY_IN_ALL_QUEUES if queues.empty?
      if user.status == :finished
        user.notice FINISHED_IN_QUEUE
        queues.each { |q| q.add_wait(user) }
      else
        queues.each { |q| q.add(user) }
      end
      update_topic
    end

    ############################################################################
    # @!group !del

    # Parse a del command either trying to remove from all queues with no
    # arguments or just removing from a specific queue according to arg.
    # @param [String] arg Describes the queue to remove the user from
    # @return [void]
    # @see Queue.remove
    def del(m, arg)
      queue = @queue_list.find_queue_by_arg(arg)
      user = m.user
      return user.notice YOU_ARE_PLAYING if playing?(user)
      return del_from_all(m, user) if arg.nil? || arg == "all"
      return user.notice QUEUE_NOT_FOUND if queue.nil?
      return user.notice YOU_NOT_IN_QUEUE unless queue.listed_either?(user)
      m.reply format(LEFT, user.nick, queue.name)
      queue.remove(user)
      update_topic
    end

    # Delete a user from all the queues they are queued in, noticing them if
    # they are not in any, otherwise announcing that they have left all queues.
    # @param [Cinch::User] user The user that wishes to remove themself
    # @return [void]
    # @see #del
    # @see Queue.remove
    def del_from_all(m, user)
      queues = @queue_list.queues.select { |q| q.listed_either?(user) }
      return user.notice YOU_NOT_IN_ANY_QUEUES if queues.empty?
      queues.each { |q| q.remove(user) }
      m.reply format(LEFT_ALL, user.nick)
      update_topic
    end

    ############################################################################
    # @!group !remove

    # Parse a remove command, only allowing ops to execute and removing the user
    # from all queues if no argument is specified, otherwise parsing the
    # argument and removing the user from the specified queue.
    # @param [String] name The nick of the user to be removed
    # @param [String] arg Describes the queue to remove the user from
    # @return [void]
    # @see #remove_from_all
    # @see #remove_from_queue
    def remove(m, name, arg)
      queue = @queue_list.find_queue_by_arg(arg)
      user = User(name)
      return m.user.notice ACCESS_DENIED unless m.channel.opped?(m.user)
      return m.user.notice USERS_NOT_FOUND if user.nil?
      return remove_from_all(m, user) if arg.nil? || arg == "all"
      return m.user.notice QUEUE_NOT_FOUND if queue.nil?
      remove_from_queue(m, user, queue)
      update_topic
    end

    # Remove a user from a specified queue and reply to the channel, or notice
    # the remover and return :not_in_queue if the user is not in the queue.
    # @param [Cinch::User] user The user to be removed
    # @param [Queue] queue The queue to remove the user from
    # @return [void]
    # @see #remove
    # @see Queue.remove
    def remove_from_queue(m, user, queue)
      unless queue.listed_either?(user)
        m.user.notice format(NOT_IN_QUEUE, user.nick)
      end
      queue.remove(user)
      m.reply format(REMOVED, user.nick, queue.name, m.user.nick)
    end

    # Remove a user from all queues, noticing if they are not in any queues and
    # alerting the user if so.
    # @param [Cinch::User] user The user to be removed
    # @return [void]
    # @see #remove
    # @see Queue.remove
    def remove_from_all(m, user)
      queues = @queue_list.queues.select { |q| q.listed_either?(user) }
      return user.notice YOU_NOT_IN_ANY_QUEUES if queues.empty?
      queues.each { |q| q.remove(user) }
      m.reply format(REMOVED, user.nick, "all queues", m.user.nick)
      update_topic
    end

    ############################################################################
    # @!group !end

    # End a queue, a command for operators that deletes a queue from the
    # queuelist and allows all current players to immeditaely join new queues.
    # @param [String] arg The queue to delete.
    # @return [void]
    # @see QueueList.remove
    def end(m, arg)
      queue = @queue_list.find_queue_by_arg(arg)
      return m.user.notice ACCESS_DENIED unless m.channel.opped?(m.user)
      return m.user.notice QUEUE_NOT_FOUND if queue.nil?
      m.reply format(ENDED, queue.name, m.user)
      queue.games.each do |game|
        game.users.each { |user| user.status = :standby }
      end
      @queue_list.remove_queue(queue)
      update_topic
    end

    ############################################################################
    # @!group !finish

    # Finish the game currently being played.
    # @param [String] arg The queue to finish the games in
    # @param [String] arg2 The number game to be finished
    # @return [void]
    # @see Queue.find_game_by_arg
    # @see Game.finish
    def finish(m, arg1, arg2)
      user = m.user
      if arg1.nil?
        game = @queue_list.find_game_playing(m.user)
        return user.notice FINISH_NOT_INGAME if game.nil?
      else
        queue = @queue_list.find_queue_by_arg(arg1)
        return user.notice QUEUE_NOT_FOUND if queue.nil?
        return user.notice NO_GAME if queue.games.empty?
        game = queue.find_game_by_arg(arg2)
        return user.notice FINISH_AMBIGUOUS_GAME if game.nil?
      end
      game.finish
      update_topic
    end

    ############################################################################
    # @!group !sub

    # Sub a user assigned to a game with one not assigned to a game, check that
    # the input is correct and then run the {#swap} function.
    # @param [String] user The nick of the user in a game
    # @param [String] sub The nick of the user not in a game
    # @return [void]
    # @see #swap
    def sub(m, user, sub)
      user_u = User(user)
      sub_u = User(sub)
      user_game = @queue_list.find_game_playing(user_u)
      sub_game = @queue_list.find_game_playing(sub_u)
      return m.user.notice USERS_NOT_FOUND if user_u.nil? || sub_u.nil?
      return m.user.notice format(NOT_PLAYING, user) if user_game.nil?
      return m.user.notice format(ALREADY_PLAYING, sub) unless sub_game.nil?
      swap(m, user_u, sub_u, user_game)
      update_topic
    end

    # Swap too users, one playing and one not.
    # @param [Cinch::User] user1 The user currently playing a game
    # @param [Cinch::User] user2 The user currently not playing a game
    # @return [void]
    # @see #sub
    # @see Queue.sub
    # @see Queue.remove
    def swap(m, user1, user2, user_game)
      user2.status = :ingame
      user1.status = :standby
      user_game.sub(user1, user2)
      m.reply format(SUBBED, user1.nick, user2.nick, m.user.nick)
    end

    ############################################################################
    # @!group !shutdown

    # Quit the program immediately, can only be performed by operator.
    # @return [void]
    def shutdown(m)
      return m.user.notice ACCESS_DENIED unless m.channel.opped?(m.user)
      m.reply format(KILLED, m.user.nick)
      abort format(KILLED, m.user.nick)
    end

    ############################################################################
    # @!group !restart

    # Effectively restart the bot, clearing the queue list and resetting all
    # users to an untracked state.
    # @return [void]
    def restart(m)
      return m.user.notice ACCESS_DENIED unless m.channel.opped?(m.user)
      m.reply format(RESTARTED, m.user.nick)
      @queue_list = QueueList.new(self)
      @channel.users.keys.each do |u|
        u.track = false
        u.status = :standby
      end
      update_topic
    end

    ############################################################################
    # @!group !save

    # Save the entire list of queues to a file so in the case of a crash/restart
    # everything does not have to be remade.
    # @param [String] file The filename to save to
    # @return [void]
    def save(m, file)
      return m.user.notice ACCESS_DENIED unless m.channel.opped?(m.user)
      File.open(File.expand_path("#{file}.json"), "w") do |f|
        f.write(@queue_list.to_json)
      end
      m.reply format(SAVED, m.user.nick)
    end

    ############################################################################
    # @!group !load

    # Load a file that has been saved earlier with !save as the current queue
    # list. If supplied with no arguments load default file.
    # @return [void]
    def load(m, file)
      file =  config[:default_file] if file.nil?
      return m.user.notice ACCESS_DENIED unless m.channel.opped?(m.user)
      begin
        f = File.read(File.expand_path("#{file}.json"))
      rescue Errno::ENOENT
        return m.reply NO_SAVE_FILE
      end
      queue_list = JSON.parse(f)
      @queue_list = QueueList.new(self)
      @queue_list.from_hash(queue_list)
      update_topic
      m.reply format(LOADED, m.user.nick)
    end

    ############################################################################
    # @!group HelperFunctions

    # Is a user currently playing in a game?
    # @param [String] user The nick of the user to test
    # @return [Boolean] Whether or not they are playing
    def playing?(user)
      user.status == :ingame
    end

    ############################################################################
  end
end
