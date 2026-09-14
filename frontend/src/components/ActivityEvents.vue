<template>
  <b-taglist>
    <b-tag v-if="views > 0" class="is-small opened">
      {{ $t('analytics.opened') }} &times;{{ views }}
    </b-tag>
    <b-tag v-if="clicks > 0" class="is-small clicked">
      {{ $t('analytics.clicked') }} &times;{{ clicks }}
      <template v-if="links > 1"> ({{ links }})</template>
    </b-tag>
    <b-tag v-if="bounces > 0" class="is-small bounced">
      {{ $t('analytics.bounced') }} ({{ bounceType }})
    </b-tag>
  </b-taglist>
</template>

<script>
import Vue from 'vue';

export default Vue.extend({
  props: {
    views: { type: Number, default: 0 },
    clicks: { type: Number, default: 0 },
    links: { type: Number, default: 0 },
    bounces: { type: Number, default: 0 },
    bounceType: { type: String, default: '' },
  },
});
</script>
