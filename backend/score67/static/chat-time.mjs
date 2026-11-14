export function chatAge(createdAt, now, t) {
  const seconds = Math.max(0, Math.floor((now - createdAt) / 1000));
  if (seconds === 0) return t('chat.age.now');
  const [key, count] = seconds < 60 ? ['seconds', seconds]
    : seconds < 3600 ? ['minutes', Math.floor(seconds / 60)]
    : seconds < 86400 ? ['hours', Math.floor(seconds / 3600)]
    : [seconds < 172800 ? 'day' : 'days', Math.floor(seconds / 86400)];
  return t(`chat.age.${key}`).replace('{n}', count);
}
