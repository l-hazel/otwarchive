class ChallengeSignup < ActiveRecord::Base
  # -1 represents all matching
  ALL = -1

  belongs_to :pseud
  belongs_to :collection

  has_many :prompts, :dependent => :destroy, :inverse_of => :challenge_signup
  has_many :requests, :dependent => :destroy, :inverse_of => :challenge_signup
  has_many :offers, :dependent => :destroy, :inverse_of => :challenge_signup

  has_many :offer_potential_matches, :class_name => "PotentialMatch", :foreign_key => 'offer_signup_id', :dependent => :destroy
  has_many :request_potential_matches, :class_name => "PotentialMatch", :foreign_key => 'request_signup_id', :dependent => :destroy

  has_many :offer_assignments, :class_name => "ChallengeAssignment", :foreign_key => 'offer_signup_id'
  has_many :request_assignments, :class_name => "ChallengeAssignment", :foreign_key => 'request_signup_id'

  has_many :request_claims, :class_name => "ChallengeClaim", :foreign_key => 'request_signup_id'

  before_destroy :clear_assignments_and_claims
  def clear_assignments_and_claims
    # remove this signup reference from any existing assignments
    offer_assignments.each {|assignment| assignment.offer_signup = nil; assignment.save}
    request_assignments.each {|assignment| assignment.request_signup = nil; assignment.save}
    request_claims.each {|claim| claim.destroy}
  end

  # we reject prompts if they are empty except for associated references
  accepts_nested_attributes_for :offers, :prompts, :requests, {:allow_destroy => true,
    :reject_if => proc { |attrs|
                          attrs[:url].blank? && attrs[:description].blank? &&
                          (attrs[:tag_set_attributes].nil? || attrs[:tag_set_attributes].all? {|k,v| v.blank?}) &&
                          (attrs[:optional_tag_set_attributes].nil? || attrs[:optional_tag_set_attributes].all? {|k,v| v.blank?})
                        }
  }

  scope :by_user, lambda {|user|
    select("DISTINCT challenge_signups.*").
    joins(:pseud => :user).
    where('users.id = ?', user.id)
  }

  scope :by_pseud, lambda {|pseud| where('pseud_id = ?', pseud.id) }

  scope :pseud_only, select(:pseud_id)

  scope :order_by_pseud, joins(:pseud).order("pseuds.name")
  
  scope :order_by_date, order("updated_at DESC")

  scope :in_collection, lambda {|collection| where('challenge_signups.collection_id = ?', collection.id)}

  ### VALIDATION

  validates_presence_of :pseud, :collection

  # only one signup per challenge!
  validates_uniqueness_of :pseud_id, :scope => [:collection_id], :message => ts("^You seem to already have signed up for this challenge.")

  # we validate number of prompts/requests/offers at the challenge
  validate :number_of_prompts
  def number_of_prompts
    if (challenge = collection.challenge)
      errors_to_add = []
      %w(offers requests).each do |prompt_type|
        allowed = self.send("#{prompt_type}_num_allowed")
        required = self.send("#{prompt_type}_num_required")
        count = eval("@#{prompt_type}") ? eval("@#{prompt_type}.size") : eval("#{prompt_type}.size")
        unless count.between?(required, allowed)
          if allowed == 0
            errors_to_add << ts("You cannot submit any #{prompt_type.pluralize} for this challenge.")
          elsif required == allowed
            errors_to_add << ts("You must submit exactly %{required} #{required > 1 ? prompt_type.pluralize : prompt_type} for this challenge. You currently have %{count}.",
              :required => required, :count => count)
          else
            errors_to_add << ts("You must submit between %{required} and %{allowed} #{prompt_type.pluralize} to sign up for this challenge. You currently have %{count}.",
              :required => required, :allowed => allowed, :count => count)
          end
        end
      end
      unless errors_to_add.empty?
        # yuuuuuck :( but so much less ugly than define-method'ing these all
        self.errors.add(:base, errors_to_add.join("</li><li>").html_safe)
      end
    end
  end

  # make sure that tags are unique across each group of prompts
  validate :unique_tags
  def unique_tags
    if (challenge = collection.challenge)
      errors_to_add = []
      %w(prompts requests).each do |prompt_type|
        restriction = case prompt_type
          when "prompts"
          then challenge.prompt_restriction
          when "requests"
          then challenge.request_restriction
        end

        if restriction
          prompts = instance_variable_get("@#{prompt_type}") || self.send("#{prompt_type}")
          TagSet::TAG_TYPES.each do |tag_type|
            if restriction.send("require_unique_#{tag_type}")
              all_tags_used = []
              prompts.each do |prompt|
                new_tags = prompt.tag_set.send("#{tag_type}_taglist")
                unless (all_tags_used & new_tags).empty?
                  errors_to_add << ts("You have submitted more than one %{prompt_type} with the same %{tag_type} tags. This challenge requires them all to be unique.",
                                      :prompt_type => prompt_type.singularize, :tag_type => tag_type)
                  break
                end
                all_tags_used += new_tags
              end
            end
          end
        end
      end
      if self.collection.challenge_type == "GiftExchange"
      %w(offers).each do |prompt_type|
        restriction = case prompt_type
          when "offers"
          then challenge.offer_restriction
        end

        if restriction
          prompts = instance_variable_get("@#{prompt_type}") || self.send("#{prompt_type}")
          TagSet::TAG_TYPES.each do |tag_type|
            if restriction.send("require_unique_#{tag_type}")
              all_tags_used = []
              prompts.each do |prompt|
                new_tags = prompt.tag_set.send("#{tag_type}_taglist")
                unless (all_tags_used & new_tags).empty?
                  errors_to_add << ts("You have submitted more than one %{prompt_type} with the same %{tag_type} tags. This challenge requires them all to be unique.",
                                      :prompt_type => prompt_type.singularize, :tag_type => tag_type)
                  break
                end
                all_tags_used += new_tags
              end
            end
          end
        end
      end
      end


      unless errors_to_add.empty?
        # yuuuuuck :( but so much less ugly than define-method'ing these all
        self.errors.add(:base, errors_to_add.join("</li><li>").html_safe)
      end
    end
  end


  # define "offers_num_allowed" etc here
  %w(offers requests).each do |prompt_type|
    %w(required allowed).each do |permission|
      define_method("#{prompt_type}_num_#{permission}") do
        collection.challenge.respond_to?("#{prompt_type}_num_#{permission}") ? collection.challenge.send("#{prompt_type}_num_#{permission}") : 0
      end
    end
  end
  
  def can_delete?(prompt)
    prompt_type = prompt.class.to_s.downcase.pluralize
    current_num_prompts = self.send(prompt_type).count
    required_num_prompts = self.send("#{prompt_type}_num_required")
    if current_num_prompts > required_num_prompts
      true
    else
      false
    end
  end  

  ### Code for generating signup summaries

  def self.generate_summary_tags(collection)
    tag_type = collection.challenge.topmost_tag_type
    summary_tags = ChallengeSignupSummary.new(collection).summary

    return [tag_type, summary_tags]
  end

  # Write the summary to a file that will then be displayed
  # takes about 12 minutes for yuletide2010 on beta, about 25 minutes on stage
  def self.generate_summary(collection)
    Resque.enqueue(ChallengeSignup, collection.id)
  end
  @queue = :collection
  def self.perform(collection_id)
    self.generate_summary_in_background(Collection.find(collection_id))
  end
  def self.generate_summary_in_background(collection)
    tag_type, summary_tags = ChallengeSignup.generate_summary_tags(collection)
    view = ActionView::Base.new(ActionController::Base.view_paths, {})
    view.class_eval do
      include ApplicationHelper
    end
    content = view.render(:partial => "challenge/#{collection.challenge.class.name.demodulize.tableize.singularize}/challenge_signups_summary",
                          :locals => {:challenge_collection => collection, :tag_type => tag_type, :summary_tags => summary_tags, :generated_live => false})
    summary_dir = ChallengeSignup.summary_dir
    FileUtils.mkdir_p(summary_dir) unless File.directory?(summary_dir)
    File.open(ChallengeSignup.summary_file(collection), "w:UTF-8") {|f| f.write(content)}
  end

  def self.summary_dir
    "#{Rails.public_path}/static/challenge_signup_summaries"
  end

  def self.summary_file(collection)
    "#{ChallengeSignup.summary_dir}/#{collection.name}_summary_content.html"
  end

  # sort alphabetically
  include Comparable
  def <=>(other)
    self.pseud.name.downcase <=> other.pseud.name.downcase
  end

  def user
    self.pseud.user
  end

  def user_allowed_to_destroy?(current_user)
    (self.pseud.user == current_user) || self.collection.user_is_maintainer?(current_user)
  end

  def user_allowed_to_see?(current_user)
    (self.pseud.user == current_user) || user_allowed_to_see_signups?(current_user)
  end

  def user_allowed_to_see_signups?(user)
    self.collection.user_is_maintainer?(user) ||
    self.collection.challenge_type == "PromptMeme" ||
      (self.challenge.respond_to?("user_allowed_to_see_signups?") && self.challenge.user_allowed_to_see_signups?(user))
  end

  def byline
    pseud.byline
  end

  # Returns nil if not a match otherwise returns PotentialMatch object
  # self is the request, other is the offer
  def match(other, settings=nil)
    no_match_required = settings.nil? || settings.no_match_required?
    potential_match_attributes = {:offer_signup => other, :request_signup => self, :collection => self.collection}
    prompt_matches = []
    unless no_match_required
      self.requests.each do |request|
        other.offers.each do |offer|
          if (match = request.match(offer, settings))
            prompt_matches << match
          end
        end
      end
      return nil if settings.num_required_prompts == ALL && prompt_matches.size != self.requests.size
    end
    if no_match_required || prompt_matches.size >= settings.num_required_prompts
      # we have a match
      potential_match_attributes[:num_prompts_matched] = prompt_matches.size
      potential_match = PotentialMatch.new(potential_match_attributes)
      potential_match.potential_prompt_matches = prompt_matches unless prompt_matches.empty?
      potential_match
    else
      nil
    end
  end

end
