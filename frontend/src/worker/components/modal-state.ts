const stack: symbol[] = [];
let previousOverflow = '';
export function retainModal(id: symbol): number {
  if (!stack.length) {
    previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
  }
  stack.push(id);
  return stack.length;
}
export function topModal(id: symbol) { return stack.at(-1) === id; }
export function releaseModal(id: symbol) {
  const index = stack.indexOf(id);
  if (index >= 0) stack.splice(index, 1);
  if (!stack.length) document.body.style.overflow = previousOverflow;
}
