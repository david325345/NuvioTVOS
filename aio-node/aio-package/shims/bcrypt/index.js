'use strict';
const bcryptjs = require('bcryptjs');
module.exports = {
  genSalt: (rounds = 10) => bcryptjs.genSalt(rounds),
  hash: (data, saltOrRounds) => bcryptjs.hash(String(data), saltOrRounds),
  compare: (data, encrypted) => bcryptjs.compare(String(data), encrypted),
  genSaltSync: (rounds = 10) => bcryptjs.genSaltSync(rounds),
  hashSync: (data, saltOrRounds) => bcryptjs.hashSync(String(data), saltOrRounds),
  compareSync: (data, encrypted) => bcryptjs.compareSync(String(data), encrypted),
  getRounds: (encrypted) => bcryptjs.getRounds(encrypted),
};
module.exports.default = module.exports;
