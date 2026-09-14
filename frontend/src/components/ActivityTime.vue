<template>
  <div>
    <span>{{ $utils.getDate(lastAt).fromNow() }}</span>
    <span class="subscriber-meta">{{ $utils.niceDate(lastAt, true) }}</span>
    <span v-if="firstAt" class="subscriber-meta">
      {{ $t('analytics.firstActivity') }}: {{ $utils.niceDate(firstAt, true) }}
    </span>
  </div>
</template>

<script>
import Vue from 'vue';

export default Vue.extend({
  props: {
    firstAt: { type: String, default: null },
    lastAt: { type: String, default: null },
  },
});
</script>
