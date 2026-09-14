<template>
  <section class="analytics content relative">
    <h1 class="title is-4">
      {{ $t('globals.terms.analytics') }}
    </h1>
    <div v-if="serverConfig.privacy.disable_tracking || !serverConfig.privacy.individual_tracking"
      class="notification is-info">
      <template v-if="serverConfig.privacy.disable_tracking">
        {{ $t('analytics.trackingDisabled') }}
      </template>
      <template v-else-if="!serverConfig.privacy.individual_tracking">
        {{ $t('analytics.nonIndividualTracking') }}
      </template>
    </div>
    <hr />

    <section v-if="!subscriber" class="audience-health mb-5">
      <b-field class="mb-4">
        <b-select v-model="listID" size="is-small" @input="onListChange">
          <option value="">{{ $t('analytics.allLists') }}</option>
          <option v-for="l in lists.results" :key="l.id" :value="l.id">
            {{ l.name }}
          </option>
        </b-select>
      </b-field>

      <div v-if="charts.recency" class="chart">
        <h4>{{ $t('analytics.engagementRecency') }}</h4>
        <p class="has-text-grey is-size-7">{{ $t('analytics.engagementRecencyHelp') }}</p>
        <chart v-if="!charts.loading" type="bar" :data="charts.recency" />
      </div>
    </section>

    <section class="subscriber-activity">
      <h4 v-if="subscriber">
        <a href="#" @click.prevent="onBack">&lsaquo; {{ $t('globals.buttons.back') }}</a>
        &nbsp;{{ subscriber.email }}
        <span class="has-text-grey-light">({{ $utils.niceNumber(camps.total) }})</span>
      </h4>
      <h4 v-else>
        {{ $t('analytics.subscriberActivity') }}
        <span class="has-text-grey-light">({{ $utils.niceNumber(subs.total) }})</span>
      </h4>

      <div class="activity-filters is-flex is-align-items-center mb-4">
        <b-field class="mb-0">
          <b-radio-button v-for="r in ranges" :key="r" v-model="range" :native-value="r" size="is-small"
            @input="onRangeChange">
            {{ r ? $t('analytics.lastDays', { days: r }) : $t('analytics.allTime') }}
          </b-radio-button>
        </b-field>

        <b-field class="mb-0">
          <b-radio-button v-for="e in ['', 'opened', 'clicked', 'bounced']" :key="e" v-model="event" :native-value="e"
            size="is-small" @input="onFilter">
            {{ e ? $t(`analytics.${e}`) : $t('analytics.allEvents') }}
          </b-radio-button>
        </b-field>

        <b-input v-if="!subscriber" v-model="search" class="activity-search mb-0" size="is-small" icon="magnify"
          expanded :placeholder="$t('subscribers.email')" @keyup.native.enter="onFilter" />
      </div>

      <div v-if="!subscriber && charts.timeline" class="chart mb-5">
        <h4>{{ $t('analytics.engagedSubscribers') }}</h4>
        <p class="has-text-grey is-size-7">{{ $t('analytics.engagedSubscribersHelp') }}</p>
        <chart v-if="!charts.loading" type="line" :data="charts.timeline" />
      </div>

      <b-table v-if="subscriber" :data="camps.results" :loading="camps.loading" backend-pagination
        :paginated="camps.total > camps.perPage" pagination-size="is-small" pagination-rounded
        @page-change="onCampsPageChange" :current-page="camps.page" :per-page="camps.perPage" :total="camps.total"
        hoverable>
        <b-table-column v-slot="props" field="campaign" :label="$tc('globals.terms.campaign', 1)">
          <a href="#" @click.prevent="onOpenCampaign(props.row)">
            {{ props.row.campaignName }}
          </a>
          <span v-if="props.row.campaignSubject" class="subscriber-meta">{{ props.row.campaignSubject }}</span>

          <ul v-if="props.row.clickedLinks && props.row.clickedLinks.length" class="clicked-links">
            <li v-for="(l, i) in props.row.clickedLinks" :key="i">
              <a href="#" @click.prevent="onOpenLink(l.url)">{{ l.url }}</a>
              <span class="count">
                &times;{{ l.count }} &middot; {{ $utils.niceDate(l.lastAt, true) }}
              </span>
            </li>
          </ul>
        </b-table-column>

        <b-table-column v-slot="props" field="events" :label="$t('analytics.events')">
          <activity-events :views="props.row.views" :clicks="props.row.clicks" :links="props.row.links"
            :bounces="props.row.bounces" :bounce-type="props.row.bounceType" />
        </b-table-column>

        <b-table-column v-slot="props" field="lastAt" :label="$t('analytics.lastActivity')" width="220">
          <activity-time :first-at="props.row.firstAt" :last-at="props.row.lastAt" />
        </b-table-column>

        <template #empty>
          <empty-placeholder />
        </template>
      </b-table>

      <b-table v-else :data="subs.results" :loading="subs.loading" backend-pagination
        :paginated="subs.total > subs.perPage" pagination-size="is-small" pagination-rounded
        @page-change="onSubsPageChange" :current-page="subs.page" :per-page="subs.perPage" :total="subs.total"
        hoverable>
        <b-table-column v-slot="props" field="email" :label="$t('subscribers.email')">
          <a href="#" @click.prevent="onSelect(props.row)">
            {{ props.row.email }}
          </a>
          <b-tag v-if="props.row.subscriberStatus !== 'enabled'" :class="props.row.subscriberStatus" class="is-small">
            {{ $t(`subscribers.status.${props.row.subscriberStatus}`) }}
          </b-tag>
          <span v-if="props.row.name" class="subscriber-meta">{{ props.row.name }}</span>
        </b-table-column>

        <b-table-column v-slot="props" field="events" :label="$t('analytics.events')">
          <activity-events :views="props.row.views" :clicks="props.row.clicks" :links="props.row.links"
            :bounces="props.row.bounces" :bounce-type="props.row.bounceType" />
        </b-table-column>

        <b-table-column v-slot="props" field="lastAt" :label="$t('analytics.lastActivity')" width="220">
          <activity-time :first-at="props.row.firstAt" :last-at="props.row.lastAt" />
        </b-table-column>

        <template #empty>
          <empty-placeholder />
        </template>
      </b-table>
    </section>
  </section>
</template>

<script>
import dayjs from 'dayjs';
import Vue from 'vue';
import { mapState } from 'vuex';
import { colors } from '../constants';
import ActivityEvents from '../components/ActivityEvents.vue';
import ActivityTime from '../components/ActivityTime.vue';
import Chart from '../components/Chart.vue';
import EmptyPlaceholder from '../components/EmptyPlaceholder.vue';

export default Vue.extend({
  components: {
    ActivityEvents,
    ActivityTime,
    Chart,
    EmptyPlaceholder,
  },

  data() {
    return {
      ranges: ['', '7', '30', '90'],
      range: '',
      event: '',
      search: '',
      listID: '',
      subscriber: null,

      charts: {
        recency: null,
        timeline: null,
        loading: false,
      },

      subs: {
        results: [], total: 0, page: 1, perPage: 20, loading: false,
      },
      camps: {
        results: [], total: 0, page: 1, perPage: 20, loading: false,
      },
    };
  },

  methods: {
    // An empty range means all time, which the API represents as empty date bounds.
    fromDate() {
      return this.range ? dayjs().subtract(parseInt(this.range, 10), 'day').format('YYYY-MM-DD HH:mm:ss') : '';
    },

    getSubscribers() {
      this.subs.loading = true;

      this.$api.getSubscribersAnalytics({
        from: this.fromDate(),
        list_id: this.listID,
        event: this.event,
        search: this.search,
        page: this.subs.page,
        per_page: this.subs.perPage,
      }).then((data) => {
        this.subs.results = data.results;
        this.subs.total = data.total;
        this.subs.perPage = data.perPage;
        this.subs.loading = false;
      }).catch(() => {
        this.subs.loading = false;
      });
    },

    getCampaigns() {
      this.camps.loading = true;

      this.$api.getSubscriberAnalytics(this.subscriber.id, {
        from: this.fromDate(),
        event: this.event,
        page: this.camps.page,
        per_page: this.camps.perPage,
      }).then((data) => {
        this.camps.results = data.results;
        this.camps.total = data.total;
        this.camps.perPage = data.perPage;
        this.camps.loading = false;
      }).catch(() => {
        this.camps.loading = false;
      });
    },

    getCharts() {
      // Chart.js only reads its data on mount, so the components are destroyed and
      // recreated via v-if while loading to make them pick up new data.
      this.charts.loading = true;

      this.$api.getSubscribersAnalyticsCharts({
        list_id: this.listID,
        from: this.fromDate(),
      }).then((data) => {
        this.charts.recency = {
          labels: data.recency.map((b) => this.$t(`analytics.recency.${b.bucket}`)),
          datasets: [{
            data: data.recency.map((b) => b.count),
            backgroundColor: colors.primary,
          }],
        };

        // A line needs at least two points to draw a segment. Anything less is an empty box.
        this.charts.timeline = data.timeline.length > 1 ? {
          labels: data.timeline.map((t) => dayjs(t.period).format(data.granularity === 'month' ? 'YYYY-MM' : 'MMM D')),
          datasets: [
            {
              label: this.$t('analytics.opened'),
              data: data.timeline.map((t) => t.views),
              borderColor: colors.primary,
            },
            {
              label: this.$t('analytics.clicked'),
              data: data.timeline.map((t) => t.clicks),
              borderColor: '#FFB50D',
            },
          ],
        } : null;

        this.charts.loading = false;
      }).catch(() => {
        this.charts.loading = false;
      });
    },

    onOpenLink(url) {
      this.$utils.confirm(this.$t('analytics.confirmOpenLink', { url }), () => {
        window.open(url, '_blank', 'noopener noreferrer');
      });
    },

    onOpenCampaign(row) {
      this.$utils.confirm(this.$t('analytics.confirmOpenCampaign', { name: row.campaignName }), () => {
        this.$router.push({ name: 'campaign', params: { id: row.campaignId } });
      });
    },

    onSelect(row) {
      this.$router.push({ query: { id: row.subscriberId } });
    },

    onBack() {
      this.$router.push({ query: {} });
    },

    onFilter() {
      if (this.subscriber) {
        this.camps.page = 1;
        this.getCampaigns();
        return;
      }

      this.subs.page = 1;
      this.getSubscribers();
    },

    // The charts ignore the event and search filters, so they only refresh on range and list changes.
    onRangeChange() {
      this.onFilter();
      if (!this.subscriber) {
        this.getCharts();
      }
    },

    onListChange() {
      this.onFilter();
      this.getCharts();
    },

    onSubsPageChange(page) {
      this.subs.page = page;
      this.getSubscribers();
    },

    onCampsPageChange(page) {
      this.camps.page = page;
      this.getCampaigns();
    },

    load() {
      const id = parseInt(this.$route.query.id, 10);
      if (!id) {
        this.subscriber = null;
        this.subs.page = 1;
        this.getSubscribers();
        this.getCharts();
        return;
      }

      // A single subscriber's per-campaign table carries the same information at a
      // finer grain than any chart could, so the charts are list-level only.
      this.$api.getSubscriber(id).then((data) => {
        this.subscriber = data;
        this.camps.page = 1;
        this.getCampaigns();
      });
    },
  },

  computed: {
    ...mapState(['serverConfig', 'lists']),
  },

  watch: {
    '$route.query.id': function onIDChange() {
      this.load();
    },
  },

  mounted() {
    this.$api.getLists({ minimal: true, per_page: 'all' });
    this.load();
  },
});
</script>
