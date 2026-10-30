<script setup lang="ts">
import { nextTick, onBeforeUnmount, ref, watch } from 'vue';
import WorkerIcon from './WorkerIcon.vue';
import { releaseModal, retainModal, topModal } from './modal-state';
const props = defineProps<{ modelValue: boolean; title: string; busy?: boolean; detail?: boolean }>();
const emit = defineEmits<{ 'update:modelValue': [value: boolean] }>();
const panel = ref<HTMLElement>();
const level = ref(1);
const id = Symbol('worker-modal');
let previousFocus: HTMLElement | null = null;
let registered = false;
function close() { if (!props.busy) emit('update:modelValue', false); }
function keydown(event: KeyboardEvent) {
  if (!props.modelValue || !topModal(id)) return;
  if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close(); }
  if (event.key !== 'Tab') return;
  const nodes = Array.from(panel.value?.querySelectorAll<HTMLElement>('button:not(:disabled),input:not(:disabled),textarea:not(:disabled),a[href],[tabindex="0"]') || [])
    .filter(node => node.getClientRects().length > 0);
  const first = nodes[0], last = nodes.at(-1);
  if (!first || !last) { event.preventDefault(); panel.value?.focus(); return; }
  if (event.shiftKey && (document.activeElement === first || !panel.value?.contains(document.activeElement))) {
    event.preventDefault(); last.focus();
  } else if (!event.shiftKey && (document.activeElement === last || !panel.value?.contains(document.activeElement))) {
    event.preventDefault(); first.focus();
  }
}
function unregister() {
  if (!registered) return;
  registered = false;
  releaseModal(id);
  document.removeEventListener('keydown', keydown, true);
  if (previousFocus?.isConnected) previousFocus.focus({ preventScroll: true });
}
watch(() => props.modelValue, async open => {
  if (!open) { unregister(); return; }
  previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  if (!registered) { registered = true; level.value = retainModal(id); document.addEventListener('keydown', keydown, true); }
  await nextTick();
  if (props.modelValue) panel.value?.focus({ preventScroll: true });
}, { immediate: true });
onBeforeUnmount(unregister);
</script>
<template>
  <Teleport to="body">
    <div v-if="modelValue" class="worker-modal-shade" :style="{ zIndex: 1000 + level * 10 }">
      <section ref="panel" class="worker-modal" :class="{ 'worker-modal-detail': detail }" role="dialog" aria-modal="true" :aria-label="title" tabindex="-1">
        <header class="worker-modal-heading"><h2>{{ title }}</h2><button class="worker-modal-close" type="button" aria-label="关闭弹窗" title="关闭弹窗" :disabled="busy" @click="close"><WorkerIcon name="close" /></button></header>
        <div class="worker-modal-body"><slot /></div>
      </section>
    </div>
  </Teleport>
</template>
