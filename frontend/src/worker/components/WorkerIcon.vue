<script setup lang="ts">
import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, Close, EditPen, Grid, Refresh, Tickets, User } from '@element-plus/icons-vue';
defineProps<{ name: 'back' | 'next' | 'expand' | 'collapse' | 'close' | 'edit' | 'jobs' | 'refresh' | 'orders' | 'profile' }>();
const icons = { back: ArrowLeft, next: ArrowRight, expand: ArrowDown, collapse: ArrowUp, close: Close, edit: EditPen, jobs: Grid, refresh: Refresh, orders: Tickets, profile: User };
</script>
<template><component :is="icons[name]" class="worker-icon" aria-hidden="true" /></template>
