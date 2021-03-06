require 'spec_helper'
require 'post_destroyer'

describe PostDestroyer do

  before do
    ActiveRecord::Base.observers.enable :all
  end

  let(:moderator) { Fabricate(:moderator) }
  let(:admin) { Fabricate(:admin) }
  let(:post) { create_post }

  describe "destroy_old_hidden_posts" do

    it "destroys posts that have been hidden for 30 days" do
      Fabricate(:admin)

      now = Time.now

      freeze_time(now - 60.days)
      topic = post.topic
      reply1 = create_post(topic: topic)

      freeze_time(now - 40.days)
      reply2 = create_post(topic: topic)
      PostAction.hide_post!(reply2, PostActionType.types[:off_topic])

      freeze_time(now - 20.days)
      reply3 = create_post(topic: topic)
      PostAction.hide_post!(reply3, PostActionType.types[:off_topic])

      freeze_time(now - 10.days)
      reply4 = create_post(topic: topic)

      freeze_time(now)
      PostDestroyer.destroy_old_hidden_posts

      reply1.reload
      reply2.reload
      reply3.reload
      reply4.reload

      reply1.deleted_at.should == nil
      reply2.deleted_at.should_not == nil
      reply3.deleted_at.should == nil
      reply4.deleted_at.should == nil
    end

  end

  describe 'destroy_old_stubs' do
    it 'destroys stubs for deleted by user posts' do
      SiteSetting.stubs(:delete_removed_posts_after).returns(24)
      Fabricate(:admin)
      topic = post.topic
      reply1 = create_post(topic: topic)
      reply2 = create_post(topic: topic)
      reply3 = create_post(topic: topic)

      PostDestroyer.new(reply1.user, reply1).destroy
      PostDestroyer.new(reply2.user, reply2).destroy

      reply2.update_column(:updated_at, 2.days.ago)

      PostDestroyer.destroy_stubs

      reply1.reload
      reply2.reload
      reply3.reload

      reply1.deleted_at.should == nil
      reply2.deleted_at.should_not == nil
      reply3.deleted_at.should == nil

      # if topic is deleted we should still be able to destroy stubs

      topic.trash!
      reply1.update_column(:updated_at, 2.days.ago)
      PostDestroyer.destroy_stubs

      reply1.reload
      reply1.deleted_at.should == nil

      # flag the post, it should not nuke the stub anymore
      topic.recover!
      PostAction.act(Fabricate(:coding_horror), reply1, PostActionType.types[:spam])

      PostDestroyer.destroy_stubs

      reply1.reload
      reply1.deleted_at.should == nil

    end

    it 'uses the delete_removed_posts_after site setting' do
      Fabricate(:admin)
      topic = post.topic
      reply1 = create_post(topic: topic)
      reply2 = create_post(topic: topic)

      PostDestroyer.new(reply1.user, reply1).destroy
      PostDestroyer.new(reply2.user, reply2).destroy

      SiteSetting.stubs(:delete_removed_posts_after).returns(1)

      reply2.update_column(:updated_at, 70.minutes.ago)

      PostDestroyer.destroy_stubs

      reply1.reload
      reply2.reload

      reply1.deleted_at.should == nil
      reply2.deleted_at.should_not == nil

      SiteSetting.stubs(:delete_removed_posts_after).returns(72)

      reply1.update_column(:updated_at, 2.days.ago)

      PostDestroyer.destroy_stubs

      reply1.reload.deleted_at.should == nil

      SiteSetting.stubs(:delete_removed_posts_after).returns(47)

      PostDestroyer.destroy_stubs

      reply1.reload.deleted_at.should_not == nil
    end

    it "deletes posts immediately if delete_removed_posts_after is 0" do
      Fabricate(:admin)
      topic = post.topic
      reply1 = create_post(topic: topic)

      SiteSetting.stubs(:delete_removed_posts_after).returns(0)

      PostDestroyer.new(reply1.user, reply1).destroy

      reply1.reload.deleted_at.should_not == nil
    end
  end

  describe 'basic destroying' do

    it "as the creator of the post, doesn't delete the post" do
      SiteSetting.stubs(:unique_posts_mins).returns(5)
      SiteSetting.stubs(:delete_removed_posts_after).returns(24)

      post2 = create_post # Create it here instead of with "let" so unique_posts_mins can do its thing

      @orig = post2.cooked
      PostDestroyer.new(post2.user, post2).destroy
      post2.reload

      post2.deleted_at.should be_blank
      post2.deleted_by.should be_blank
      post2.user_deleted.should == true
      post2.raw.should == I18n.t('js.post.deleted_by_author', {count: 24})
      post2.version.should == 2

      # lets try to recover
      PostDestroyer.new(post2.user, post2).recover
      post2.reload
      post2.version.should == 3
      post2.user_deleted.should == false
      post2.cooked.should == @orig
    end

    context "as a moderator" do
      it "deletes the post" do
        PostDestroyer.new(moderator, post).destroy
        post.deleted_at.should be_present
        post.deleted_by.should == moderator
      end

      it "updates the user's post_count" do
        author = post.user
        expect {
          PostDestroyer.new(moderator, post).destroy
          author.reload
        }.to change { author.post_count }.by(-1)
      end

      it "creates a new user history entry" do
        expect {
          PostDestroyer.new(moderator, post).destroy
        }.to change { UserHistory.count}.by(1)
      end
    end

    context "as an admin" do
      it "deletes the post" do
        PostDestroyer.new(admin, post).destroy
        post.deleted_at.should be_present
        post.deleted_by.should == admin
      end

      it "updates the user's post_count" do
        author = post.user
        expect {
          PostDestroyer.new(admin, post).destroy
          author.reload
        }.to change { author.post_count }.by(-1)
      end
    end

  end

  context 'deleting the second post in a topic' do

    let(:user) { Fabricate(:user) }
    let!(:post) { create_post(user: user) }
    let(:topic) { post.topic.reload }
    let(:second_user) { Fabricate(:coding_horror) }
    let!(:second_post) { create_post(topic: topic, user: second_user) }

    before do
      PostDestroyer.new(moderator, second_post).destroy
    end

    it 'resets the last_poster_id back to the OP' do
      topic.last_post_user_id.should == user.id
    end

    it 'resets the last_posted_at back to the OP' do
      topic.last_posted_at.to_i.should == post.created_at.to_i
    end

    context 'topic_user' do

      let(:topic_user) { second_user.topic_users.find_by(topic_id: topic.id) }

      it 'clears the posted flag for the second user' do
        topic_user.posted?.should == false
      end

      it "sets the second user's last_read_post_number back to 1" do
        topic_user.last_read_post_number.should == 1
      end

      it "sets the second user's last_read_post_number back to 1" do
        topic_user.highest_seen_post_number.should == 1
      end

    end

  end

  context "deleting a post belonging to a deleted topic" do
    let!(:topic) { post.topic }

    before do
      topic.trash!(admin)
      post.reload
    end

    context "as a moderator" do
      before do
        PostDestroyer.new(moderator, post).destroy
      end

      it "deletes the post" do
        post.deleted_at.should be_present
        post.deleted_by.should == moderator
      end
    end

    context "as an admin" do
      before do
        PostDestroyer.new(admin, post).destroy
      end

      it "deletes the post" do
        post.deleted_at.should be_present
        post.deleted_by.should == admin
      end

      it "creates a new user history entry" do
        expect {
          PostDestroyer.new(admin, post).destroy
        }.to change { UserHistory.count}.by(1)
      end
    end
  end

  describe 'after delete' do

    let!(:coding_horror) { Fabricate(:coding_horror) }
    let!(:post) { Fabricate(:post, raw: "Hello @CodingHorror") }

    it "should feature the users again (in case they've changed)" do
      Jobs.expects(:enqueue).with(:feature_topic_users, has_entries(topic_id: post.topic_id, except_post_id: post.id))
      PostDestroyer.new(moderator, post).destroy
    end

    describe 'with a reply' do

      let!(:reply) { Fabricate(:basic_reply, user: coding_horror, topic: post.topic) }
      let!(:post_reply) { PostReply.create(post_id: post.id, reply_id: reply.id) }

      it 'changes the post count of the topic' do
        post.reload
        lambda {
          PostDestroyer.new(moderator, reply).destroy
          post.topic.reload
        }.should change(post.topic, :posts_count).by(-1)
      end

      it 'lowers the reply_count when the reply is deleted' do
        lambda {
          PostDestroyer.new(moderator, reply).destroy
        }.should change(post.post_replies, :count).by(-1)
      end

      it 'should increase the post_number when there are deletion gaps' do
        PostDestroyer.new(moderator, reply).destroy
        p = Fabricate(:post, user: post.user, topic: post.topic)
        p.post_number.should == 3
      end

    end

  end

  context '@mentions' do
    it 'removes notifications when deleted' do
      user = Fabricate(:evil_trout)
      post = create_post(raw: 'Hello @eviltrout')
      lambda {
        PostDestroyer.new(Fabricate(:moderator), post).destroy
      }.should change(user.notifications, :count).by(-1)
    end
  end

  describe "post actions" do
    let(:second_post) { Fabricate(:post, topic_id: post.topic_id) }
    let!(:bookmark) { PostAction.act(moderator, second_post, PostActionType.types[:bookmark]) }
    let!(:flag) { PostAction.act(moderator, second_post, PostActionType.types[:off_topic]) }

    it "should delete public post actions and agree with flags" do
      second_post.expects(:update_flagged_posts_count)

      PostDestroyer.new(moderator, second_post).destroy

      PostAction.find_by(id: bookmark.id).should == nil

      off_topic = PostAction.find_by(id: flag.id)
      off_topic.should_not == nil
      off_topic.agreed_at.should_not == nil

      second_post.reload
      second_post.bookmark_count.should == 0
      second_post.off_topic_count.should == 1
    end
  end

  describe "user actions" do
    let(:codinghorror) { Fabricate(:coding_horror) }
    let(:second_post) { Fabricate(:post, topic_id: post.topic_id) }

    def create_user_action(action_type)
      UserAction.log_action!({
        action_type: action_type,
        user_id: codinghorror.id,
        acting_user_id: codinghorror.id,
        target_topic_id: second_post.topic_id,
        target_post_id: second_post.id
      })
    end

    it "should delete the user actions" do
      bookmark = create_user_action(UserAction::BOOKMARK)
      like = create_user_action(UserAction::LIKE)

      PostDestroyer.new(moderator, second_post).destroy

      expect(UserAction.find_by(id: bookmark.id)).to be_nil
      expect(UserAction.find_by(id: like.id)).to be_nil
    end
  end

  describe 'topic links' do
    let!(:first_post)  { Fabricate(:post) }
    let!(:topic)       { first_post.topic }
    let!(:second_post) { Fabricate(:post_with_external_links, topic: topic) }

    before { TopicLink.extract_from(second_post) }

    it 'should destroy the topic links when moderator destroys the post' do
      PostDestroyer.new(moderator, second_post.reload).destroy
      expect(topic.topic_links.count).to eq(0)
    end

    it 'should destroy the topic links when the user destroys the post' do
      PostDestroyer.new(second_post.user, second_post.reload).destroy
      expect(topic.topic_links.count).to eq(0)
    end
  end

end

