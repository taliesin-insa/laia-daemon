#!/usr/bin/env Rscript
library(boot)

args = commandArgs(trailingOnly=TRUE)
if(length(args) != 1) {
  stop('Provide the errors file, computed with utils/compute-errors.sh')
}

df <- read.table(args[1], header=FALSE)
f <- function(data, indices) {
  sum_err <- sum(data[indices, 'V2'])
  sum_sub <- sum(data[indices, 'V3'])
  sum_del <- sum(data[indices, 'V4'])
  sum_ins <- sum(data[indices, 'V5'])
  sum_len <- sum(data[indices, 'V6'])
  return (c(sum_err / sum_len * 100,
          sum_sub / sum_len * 100,
          sum_del / sum_len * 100,
	  sum_ins / sum_len * 100))
}
results <- boot(data=df, statistic=f, R=max(5000, nrow(df)))
ci1 <- boot.ci(results, type='perc', index=1)
ci2 <- boot.ci(results, type='perc', index=2)
ci3 <- boot.ci(results, type='perc', index=3)
ci4 <- boot.ci(results, type='perc', index=4)

cat(sprintf('%%ERR %.2f [%.2f -- %.2f]\n',
            ci1['t0'], ci1['percent'][[1]][4], ci1['percent'][[1]][5]))
cat(sprintf('%%SUB %.2f [%.2f -- %.2f]\n',
            ci2['t0'], ci2['percent'][[1]][4], ci2['percent'][[1]][5]))
cat(sprintf('%%DEL %.2f [%.2f -- %.2f]\n',
            ci3['t0'], ci3['percent'][[1]][4], ci3['percent'][[1]][5]))
cat(sprintf('%%INS %.2f [%.2f -- %.2f]\n',
            ci4['t0'], ci4['percent'][[1]][4], ci4['percent'][[1]][5]))
